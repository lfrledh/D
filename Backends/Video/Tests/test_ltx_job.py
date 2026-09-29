"""CPU media checks; native FFmpeg fixtures require explicit local tool paths."""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'Adapters'))
import ltx_job as m
import ltx_engine_entry
from owned_video_process import run_owned


class LTXMediaTests(unittest.TestCase):
    def test_tempfile_does_not_fall_back_from_explicit_task_directory(self):
        previous=tempfile.tempdir
        try:
            with patch.dict(os.environ,{'TMPDIR':str(self.root)}):
                ltx_engine_entry.fix_temporary_directory()
            with tempfile.NamedTemporaryFile() as f:self.assertEqual(Path(f.name).parent,self.root)
            missing=self.root/'not-created'
            tempfile.tempdir=str(missing)
            with self.assertRaises(FileNotFoundError):tempfile.NamedTemporaryFile()
            with patch.dict(os.environ,{'TMPDIR':str(missing)}):
                with self.assertRaises(FileNotFoundError):ltx_engine_entry.fix_temporary_directory()
        finally:tempfile.tempdir=previous

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.request = dict(width=64, height=64, frames=9, fps=24)
        self.probe = {'streams': [
            dict(codec_type='video', codec_name='h264', width=64, height=64,
                 nb_read_frames='9', avg_frame_rate='24/1', duration='0.375', start_time='0'),
            dict(codec_type='audio', codec_name='aac', sample_rate='48000', channels=2,
                 duration='0.375', start_time='0')]}

    def test_structural_and_timeline_rejection(self):
        self.assertEqual(m.check_probe(self.probe, self.request)['frames'], 9)
        cases = [(0, 'width', 128), (0, 'nb_read_frames', '8'), (0, 'avg_frame_rate', '25/1'),
                 (0, 'duration', '0.5'), (0, 'codec_name', 'hevc'),
                 (1, 'duration', '1.0'), (1, 'start_time', '0.3'),
                 (1, 'channels', True), (1, 'sample_rate', '0')]
        for stream, key, value in cases:
            with self.subTest(key=key, value=value):
                probe=copy.deepcopy(self.probe);probe['streams'][stream][key]=value
                with self.assertRaises(ValueError):m.check_probe(probe,self.request)
        with self.assertRaises(ValueError):m.check_probe({'streams':self.probe['streams'][:1]},self.request)

    def fake_run(self, argv, label, timeout):
        if label=='decode-log': self.assertIn('-xerror',argv)
        log=self.root/(label+'.json');log.write_text(json.dumps(self.probe))
        return dict(status='success',stdout_truncated=False,stdout_log=str(log))

    def test_cancellation_during_hash_cannot_publish_success(self):
        output=self.root/'candidate.mp4';output.write_bytes(b'controlled fixture')
        event=threading.Event()
        def digest(path):event.set();return '0'*64
        with patch.object(m,'_digest',side_effect=digest):
            with self.assertRaises(InterruptedError):
                m.verify_candidate(output,self.request,ffmpeg='/test/ffmpeg',ffprobe='/test/ffprobe',run=self.fake_run,cancel_event=event)

    def test_decode_failure_and_truncated_probe_are_not_verified(self):
        output=self.root/'candidate.mp4';output.write_bytes(b'controlled fixture')
        for failed in ['probe-log','decode-log']:
            def run(argv,label,timeout):
                result=self.fake_run(argv,label,timeout)
                if label==failed:result['status']='failed'
                return result
            with self.assertRaises(ValueError):
                m.verify_candidate(output,self.request,ffmpeg='/test/ffmpeg',ffprobe='/test/ffprobe',run=run,cancel_event=threading.Event())
        def truncated(argv,label,timeout):
            result=self.fake_run(argv,label,timeout);result['stdout_truncated']=True;return result
        with self.assertRaises(ValueError):
            m.verify_candidate(output,self.request,ffmpeg='/test/ffmpeg',ffprobe='/test/ffprobe',run=truncated,cancel_event=threading.Event())

    @unittest.skipUnless(os.environ.get('D_VIDEO_TEST_FFMPEG') and os.environ.get('D_VIDEO_TEST_FFPROBE'), 'explicit native tools required')
    def test_real_av_decode_and_damaged_payload(self):
        ffmpeg=os.environ['D_VIDEO_TEST_FFMPEG'];ffprobe=os.environ['D_VIDEO_TEST_FFPROBE']
        output=self.root/'source 原件.mp4'
        command=[ffmpeg,'-v','error','-nostdin','-f','lavfi','-i','testsrc2=size=64x64:rate=24',
                 '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','0.375',
                 '-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','aac','-ac','2',str(output)]
        subprocess.run(command,check=True,timeout=30,stdin=subprocess.DEVNULL,capture_output=True)
        original=output.read_bytes();event=threading.Event()
        def run(argv,label,timeout):
            logs=self.root/('logs-'+str(len(list(self.root.iterdir()))));logs.mkdir()
            return run_owned(argv,cwd=str(self.root),environment={'PATH':'/usr/bin:/bin','TMPDIR':str(self.root)},
                log_directory=str(logs),timeout_seconds=timeout,grace_seconds=1,cancel_event=event)
        verified=m.verify_candidate(output,self.request,ffmpeg=ffmpeg,ffprobe=ffprobe,run=run,cancel_event=event)
        self.assertTrue(verified['media_verified']);self.assertEqual(output.read_bytes(),original)
        self.assertEqual(verified['sha256'],hashlib.sha256(original).hexdigest())
        # Corrupt only this new test-owned copy, retaining MP4 container boxes.
        bad=bytearray(original);offset=0;modified=False
        while offset+8<=len(bad):
            size=struct.unpack('>I',bad[offset:offset+4])[0];kind=bytes(bad[offset+4:offset+8])
            if size<8:break
            if kind==b'mdat':
                bad[offset+8:offset+size]=b'\xff'*(size-8);modified=True;break
            offset+=size
        self.assertTrue(modified)
        damaged=self.root/'damaged.mp4';damaged.write_bytes(bad)
        with self.assertRaises((ValueError,KeyError)):
            m.verify_candidate(damaged,self.request,ffmpeg=ffmpeg,ffprobe=ffprobe,run=run,cancel_event=event)
        decode=run([ffmpeg,'-v','error','-xerror','-nostdin','-i',str(damaged),'-map','0:v:0','-map','0:a:0','-f','null','-'],'damaged-direct',30)
        self.assertEqual(decode['status'],'failed')
        self.assertEqual(output.read_bytes(),original)


if __name__=='__main__':unittest.main()
