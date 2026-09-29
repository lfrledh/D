"""Offline LTX 2.3 execution in a new private task directory.

This is an adapter entry, not a second queue or an App asset store. The host
must hold D's heavy execution and model-use leases until this process drains.
The private candidate is never published/overwritten into a user's project here.
"""
from __future__ import annotations
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import threading

from ltx_admission import admit_ltx23
from ltx_plan import build_plan
from owned_video_process import run_owned


def _write_json(path, value):
    with path.open('x', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=2, allow_nan=False)
        f.write('\n')


def _digest(path):
    with path.open('rb') as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise ValueError('Expected a regular file')
        h=hashlib.sha256()
        for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
        return h.hexdigest()


def _confirm_tokenizer_patch(engine):
    # This entry targets a prepared CPython 3.12 local runtime. No model imports
    # or site discovery from the caller's current environment.
    root=engine.parent.parent/'lib/python3.12/site-packages'
    record=json.loads((Path(__file__).parent/'Patches/ltx-reject-token-truncation.json').read_bytes())
    for row in record['files']:
        path=root/row['path'].split('/src/',1)[1]
        if path.is_symlink() or _digest(path)!=row['after_sha256']:
            raise ValueError('LTX tokenizer patch is missing or changed: '+str(path))
    return record['commit']


def check_probe(probe, request):
    """Check measured media facts; full decode is separately mandatory."""
    streams=probe.get('streams')
    if not isinstance(streams,list) or len(streams)!=2:
        raise ValueError('Expected exactly one video and one audio stream')
    video=[s for s in streams if s.get('codec_type')=='video']
    audio=[s for s in streams if s.get('codec_type')=='audio']
    if len(video)!=1 or len(audio)!=1:raise ValueError('Missing or ambiguous AV streams')
    v,a=video[0],audio[0]
    if v.get('codec_name')!='h264' or a.get('codec_name')!='aac':raise ValueError('Unsupported generated AV codecs')
    if any(type(v.get(k)) is not int or v[k]!=request[k] for k in ['width','height']):raise ValueError('Generated dimensions differ')
    frames=int(v['nb_read_frames'])
    if frames!=request['frames']:raise ValueError('Decoded frame count differs')
    rate=Fraction(v['avg_frame_rate'])
    requested=Fraction(str(request['fps']))
    # The pinned CLI accepts decimal fps. Compare the reported rate, never
    # advertise bit-exact rational support from the value-only Swift contract.
    if rate<=0 or abs(float(rate/requested)-1)>1e-8:raise ValueError('Generated frame rate differs')
    sample_rate=int(a['sample_rate']);channels=a.get('channels')
    if sample_rate<=0 or sample_rate>192000 or type(channels)is not int or not 1<=channels<=8:raise ValueError('Invalid audio format')
    vd=Fraction(v['duration']);ad=Fraction(a['duration'])
    vs=Fraction(v.get('start_time','0'));ass=Fraction(a.get('start_time','0'))
    if vd<=0 or ad<=0 or abs(float(vd-Fraction(frames,1)/rate))>1e-5:raise ValueError('Video timeline differs')
    tolerance=Fraction(1,1)/rate+Fraction(2048,sample_rate)
    if abs(vs-ass)>tolerance or abs(vd-ad)>tolerance:raise ValueError('AV timeline exceeds one frame plus two AAC packets')
    return {'width':v['width'],'height':v['height'],'frames':frames,
            'fps_numerator':rate.numerator,'fps_denominator':rate.denominator,
            'video_codec':v['codec_name'],'audio_codec':a['codec_name'],
            'audio_sample_rate':sample_rate,'audio_channels':channels,
            'video_duration':str(vd),'audio_duration':str(ad),
            'video_start':str(vs),'audio_start':str(ass),
            'sync_tolerance_seconds':float(tolerance)}


def verify_candidate(output, request, *, ffmpeg, ffprobe, run, cancel_event):
    """Verify private output without regenerating it; never publishes an asset."""
    if output.is_symlink() or not output.is_file():
        raise ValueError('Engine did not produce a regular private MP4')
    probe_result=run([str(ffprobe),'-v','error','-count_frames','-show_streams','-of','json',str(output)],'probe-log',180)
    if probe_result['status']!='success' or probe_result['stdout_truncated']:
        raise ValueError('Media probe did not complete')
    info=check_probe(json.loads(Path(probe_result['stdout_log']).read_bytes()),request)
    decode=run([str(ffmpeg),'-v','error','-xerror','-nostdin','-i',str(output),'-map','0:v:0','-map','0:a:0','-f','null','-'],'decode-log',180)
    if decode['status']!='success':raise ValueError('Complete AV decode failed or was cancelled')
    if cancel_event.is_set():raise InterruptedError('Cancelled before candidate verification')
    digest=_digest(output)
    if cancel_event.is_set():raise InterruptedError('Cancelled during candidate verification')
    return dict(media_verified=True,media=info,sha256=digest,candidate_file=output.name,
                probe_process=probe_result,decode_process=decode)


def execute(request, *, engine, model, text_encoder, run_directory, ffmpeg, ffprobe,
            timeout_seconds, cancel_event):
    engine,model,text_encoder,run_directory,ffmpeg,ffprobe=map(Path,(engine,model,text_encoder,run_directory,ffmpeg,ffprobe))
    if not all(p.is_absolute() for p in [engine,model,text_encoder,run_directory,ffmpeg,ffprobe]):raise ValueError('All paths must be explicit and absolute')
    for p in [engine,ffmpeg,ffprobe]:
        if not p.is_file() or not os.access(p,os.X_OK):raise ValueError('Local executable missing: '+str(p))
    if ffmpeg.parent!=ffprobe.parent:raise ValueError('FFmpeg tools must share the explicit tool directory')
    actual=run_directory.resolve()
    for protected in [model.resolve(),text_encoder.resolve(),engine.parent.parent.resolve()]:
        if actual==protected or protected in actual.parents or actual in protected.parents:raise ValueError('Task directory overlaps protected model/runtime')
    if cancel_event.is_set():raise InterruptedError('Cancelled before resource admission')
    # Hash and inspect pinned packs before any GPU/model code. May be slow on SSD.
    admission=admit_ltx23(request['profile'],model=model,text_encoder=text_encoder,cancelled=cancel_event.is_set)
    if cancel_event.is_set():raise InterruptedError('Cancelled after resource admission')
    upstream=_confirm_tokenizer_patch(engine)
    run_directory.mkdir(mode=0o700,exist_ok=False)
    for name in ['cache','tmp','engine-log','probe-log','decode-log']:(run_directory/name).mkdir(mode=0o700)
    output=run_directory/'candidate.mp4'
    plan=build_plan(request,engine=engine,model=model,text_encoder=text_encoder,output=output)
    # Same installed CLI function and arguments; this small entry pins tempfile
    # before upstream imports so disk failure cannot silently move audio to /tmp.
    python=engine.parent/'python'
    if not python.is_file() or not os.access(python,os.X_OK):raise ValueError('Prepared LTX Python is unavailable')
    argv=[str(python),'-B',str(Path(__file__).parent/'ltx_engine_entry.py'),*plan['argv'][1:]]
    plan['actual_argv']=argv
    env={'PATH':str(ffmpeg.parent)+':/usr/bin:/bin','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8',
         'PYTHONNOUSERSITE':'1','PYTHONDONTWRITEBYTECODE':'1','HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1',
         'HF_HOME':str(run_directory/'cache/hf'),'XDG_CACHE_HOME':str(run_directory/'cache'),
         'TMPDIR':str(run_directory/'tmp'),'LTX2_GEMMA_MAX_LENGTH':'1024'}
    _write_json(run_directory/'request.json',request)
    _write_json(run_directory/'admission.json',admission)
    _write_json(run_directory/'plan.json',plan)
    def run(argv,label,timeout):
        return run_owned(argv,cwd=str(run_directory),environment=env,log_directory=str(run_directory/label),
                         timeout_seconds=timeout,grace_seconds=5,cancel_event=cancel_event)
    result=run(argv,'engine-log',timeout_seconds)
    record={'schema':'d.ltx.private-candidate.v1','request':request,'engine_source':upstream,
            'engine_process':result,'published':False,'media_verified':False}
    if result['status']!='success':
        _write_json(run_directory/'result.json',record);return record
    try:
        record.update(verify_candidate(output,request,ffmpeg=ffmpeg,ffprobe=ffprobe,run=run,cancel_event=cancel_event))
    except Exception as error:
        record['verification_error']={'type':type(error).__name__,'message':str(error)}
        _write_json(run_directory/'result.json',record)
        raise
    _write_json(run_directory/'result.json',record)
    return record


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for field in ['request','engine','model','text-encoder','run-directory','ffmpeg','ffprobe']:parser.add_argument('--'+field,required=True)
    parser.add_argument('--timeout',type=float,default=1800)
    args=parser.parse_args();event=threading.Event()
    for sig in [signal.SIGINT,signal.SIGTERM]:signal.signal(sig,lambda signum,frame:event.set())
    with Path(args.request).open('rb') as f:raw=f.read(1024*1024+1)
    if len(raw)>1024*1024:raise ValueError('Request exceeds 1 MiB')
    result=execute(json.loads(raw),engine=args.engine,model=args.model,text_encoder=args.text_encoder,
                   run_directory=args.run_directory,ffmpeg=args.ffmpeg,ffprobe=args.ffprobe,
                   timeout_seconds=args.timeout,cancel_event=event)
    print(json.dumps({'status':result['engine_process']['status'],'media_verified':result['media_verified'],'published':False}),flush=True)
    return 0 if result['media_verified'] else 2

if __name__=='__main__':
    try:sys.exit(main())
    except Exception as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr,flush=True)
        sys.exit(2)
