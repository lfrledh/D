#!/usr/bin/env python3
"""Strict offline replay audit. Does not send events or infer display FPS."""
import argparse,json,math,re,uuid
from pathlib import Path
STAGES=('intent','posted','received','handler-return-state')
IDENTITY=('window','frame','scale','screen','project','instance','graph','nodes','edges','runs','assets','canvasContext','tool')
def finite(x):return isinstance(x,(int,float)) and not isinstance(x,bool) and math.isfinite(x)
def distribution(values):
 v=sorted(x for x in values if finite(x))
 if not v:return {'n':0}
 def q(p):return v[min(len(v)-1,math.ceil(p*len(v))-1)]*1000
 return {'n':len(v),'p50_ms':q(.5),'p95_ms':q(.95),'max_ms':v[-1]*1000}
def valid_uuid(value):
 try:return isinstance(value,str) and str(uuid.UUID(value)).lower()==value.lower()
 except (ValueError,TypeError,AttributeError):return False
def expected_slots(interaction,seconds,profile='performance'):
 if profile=='qualification-low-load-v1':
  out=[]
  def add(t,kind,dx=0,wheel=0):out.append(dict(sequence=len(out),seconds=t,kind=kind,dx=dx,dy=0,wheel=wheel))
  if interaction=='ZOOM':
   for i,w in enumerate((1,1,-1,-1),1):add(i*.25,'wheel',wheel=w)
  else:
   add(0,'down')
   for i,x in enumerate((3,6,9,12) if interaction=='NODE' else (8,16,8,0),1):add(i*.25,'drag',x)
   add(1.25,'up',12 if interaction=='NODE' else 0)
  return out
 hz=20 if interaction=='ZOOM' else 60;count=int(seconds*hz);out=[]
 def add(t,kind,dx,dy,wheel):out.append(dict(sequence=len(out),seconds=t,kind=kind,dx=dx,dy=dy,wheel=wheel))
 if interaction!='ZOOM':add(0,'down',0,0,0)
 for i in range(1,count+1):
  phase=i/count*4*math.pi
  x=0 if interaction=='ZOOM' else ((12 if interaction=='NODE' else 0) if i==count else 32*math.sin(phase)+(12*i/count if interaction=='NODE' else 0))
  y=0 if interaction=='ZOOM' or i==count else 12*math.sin(2*phase)
  add(i/hz,'wheel' if interaction=='ZOOM' else 'drag',x,y,(1 if i%16<8 else -1) if interaction=='ZOOM' else 0)
 if interaction!='ZOOM':add(seconds+1/60,'up',12 if interaction=='NODE' else 0,0,0)
 return out
def analyze(report,plan,rows,completion=None):
 revision=report.get('protocolRevision',1);profile=plan.get('profile','performance');qualification=profile=='qualification-low-load-v1'
 stages_required=(('intent','post-begin','posted','post-return','received','handler-return-state') if revision==3 else ('intent','main-enter','post-begin','posted','received','handler-return-state')) if revision>=2 else STAGES
 issues=[];
 if revision not in (1,2,3):issues.append('unsupported-protocol-revision')
 if revision>=2 and (profile not in ('performance','qualification-low-load-v1') or report.get('profile')!=profile):issues.append('profile-mismatch')
 if qualification and revision!=2:issues.append('qualification-requires-revision-2')
 slots=plan.get('slots',[]);keys=[s.get('sequence') for s in slots]
 if not slots or any(not isinstance(k,int) or isinstance(k,bool) or k<0 for k in keys) or len(set(keys))!=len(keys):issues.append('invalid-plan-identities')
 times=[s.get('seconds') for s in slots]
 if any(not finite(t) or t<0 for t in times) or any(b<=a for a,b in zip(times,times[1:]) if finite(a) and finite(b)):issues.append('invalid-plan-times')
 interaction=plan.get('interaction');duration=plan.get('activeSeconds')
 if interaction not in ('NODE','PAN','ZOOM') or not finite(duration) or duration not in ((1.25,) if qualification else (2,8)):issues.append('unsupported-plan-protocol')
 else:
  expected=expected_slots(interaction,duration,profile)
  if len(expected)!=len(slots):issues.append('invalid-plan-count')
  for actual,wanted in zip(slots,expected):
   if type(actual.get('wheel')) is not int or actual.get('kind')!=wanted['kind']:issues.append('invalid-plan-payload')
   for field in ('sequence','seconds','dx','dy','wheel'):
    if not finite(actual.get(field)) or abs(actual[field]-wanted[field])>1e-7:issues.append('invalid-plan-payload')
  if plan.get('lateLimit') != (.25 if qualification else (.05 if interaction=='ZOOM' else 1/30)):issues.append('invalid-plan-late-limit')
 if report.get('schema')!=1 or report.get('level')!='B_IN_PROCESS_FULL_APP_PENDING_QUALIFICATION':issues.append('unsupported-record-protocol')
 if type(report.get('pilot')) is not bool or (report.get('pilot') is True)!=(qualification or duration==2):issues.append('pilot-plan-mismatch')
 epoch=report.get('epoch');finished=report.get('finished');start=report.get('captureStart')
 if not all(finite(x) for x in (epoch,finished,start)) or not start<=epoch<finished:issues.append('invalid-capture-times')
 if report.get('clock')!='systemUptime-seconds':issues.append('unknown-clock')
 for key in ('pid','processLaunch','executable','bundle','source'):
  if not report.get(key) or report.get(key)=='unknown':issues.append('missing-identity:'+key)
 if report.get('bundle')!='first-test.D.performance-phase2':issues.append('unexpected-diagnostic-bundle')
 if type(report.get('pid')) is not int or report['pid']<=0:issues.append('invalid-pid')
 if not isinstance(report.get('source'),str) or re.fullmatch('[0-9a-f]{40}',report['source']) is None:issues.append('invalid-source')
 if not isinstance(report.get('executable'),str) or not report['executable'].startswith('/'):issues.append('invalid-executable')
 if report.get('interaction')!=plan.get('interaction') or plan.get('interaction') not in ('NODE','PAN','ZOOM'):issues.append('interaction-mismatch')
 before,after=report.get('before',{}),report.get('after',{})
 for k in IDENTITY:
  if k not in before or k not in after or before.get(k) is None or after.get(k) is None:issues.append('missing-scene:'+k)
  elif before[k]!=after[k]:issues.append('scene-changed:'+k)
 for scene in (before,after):
  for key in ('project','instance','graph'):
   if not valid_uuid(scene.get(key)):issues.append('invalid-scene-identity:'+key)
  if type(scene.get('window')) is not int or scene['window']<=0:issues.append('invalid-window')
  if not finite(scene.get('scale')) or scene['scale']<=0:issues.append('invalid-scale')
  if not all(finite(scene.get(k)) for k in ('zoom','clipX','clipY')):issues.append('invalid-viewport')
  for key in ('nodes','edges','runs','assets'):
   if type(scene.get(key)) is not int or scene[key]<0:issues.append('invalid-scene-count:'+key)
 if not finite(before.get('zoom')) or abs(before['zoom']-1)>.001:issues.append('unexpected-starting-zoom')
 if report.get('graphCommitVerified') is not True:issues.append('graph-commit-not-verified')
 if issues and any(i in issues for i in ('invalid-plan-identities','invalid-plan-times','invalid-capture-times','unsupported-plan-protocol','invalid-plan-count','invalid-plan-payload')):
  return {'qualification':'INVALID','issues':sorted(set(issues)),'no_claims':['hardware input latency','presented FPS','GPU duration','causal attribution']}
 grouped={s['sequence']:{} for s in slots}; aux={'geometry-observed','stopped','sending-ended'}
 if revision>=2:
  ended=[r for r in rows if r.get('stage')=='sending-ended']
  if len(ended)!=1:issues.append('sending-ended-missing-or-duplicate')
  if not isinstance(completion,dict):issues.append('missing-completion')
  else:
   if completion.get('segment')!=report.get('segment') or completion.get('interaction')!=interaction:issues.append('completion-identity-mismatch')
   if completion.get('sendingStopped') is not True:issues.append('sending-not-stopped')
   if completion.get('resetGraphVerified') is not True:issues.append('reset-not-verified')
   if revision==3 and completion.get('resetUndoVerified') is not True:issues.append('reset-undo-not-verified')
   if completion.get('reason'):issues.append('completion-failed:'+str(completion['reason']))
   if not finite(completion.get('time')) or completion['time']<finished:issues.append('invalid-completion-time')
  for row in rows:
   if row.get('stage')=='posted' and len(ended)==1 and finite(row.get('time')) and finite(ended[0].get('time')) and row['time']>ended[0]['time']:issues.append('post-after-sending-ended')
   if revision==3 and row.get('stage')=='post-return' and len(ended)==1 and finite(row.get('time')) and finite(ended[0].get('time')) and row['time']>ended[0]['time']+1e-6:issues.append('post-return-after-sending-ended')
 for row in rows:
  seq=row.get('sequence');stage=row.get('stage');time=row.get('time')
  if not finite(time) or not start<=time<=finished+0.001:issues.append('invalid-or-out-of-window-time');continue
  if type(seq) is not int:issues.append('invalid-row-identity');continue
  if seq == -1:
   if stage=='stopped':issues.append('stop-record:'+str(row.get('detail')))
   elif stage not in aux:issues.append('unknown-aux-stage')
   continue
  if seq not in grouped:issues.append('unknown-sequence');continue
  if stage not in stages_required+('post-refused','cancelled-before-post','late-abort','burst-prevented','receive-refused','scheduler-stop'):issues.append('unknown-stage')
  if stage in ('post-refused','cancelled-before-post','late-abort','burst-prevented','receive-refused','scheduler-stop'):issues.append('cancelled-or-refused-slot')
  grouped[seq].setdefault(stage,[]).append(row)
 delays={k:[] for k in ('planned_to_intent','planned_to_posted','intent_to_posted','posted_to_received','received_to_handler_return')}
 if revision==2:delays.update({k:[] for k in ('intent_to_main_enter','main_enter_to_post_begin','post_begin_to_posted')})
 if revision==3:delays.update({k:[] for k in ('intent_to_post_begin','post_begin_to_entry','post_entry_to_return')})
 posted=[];received=[];states=[];by_slot={s['sequence']:s for s in slots}
 for seq,stages in grouped.items():
  s=by_slot[seq];planned=epoch+s['seconds']
  for stage in stages_required:
   if len(stages.get(stage,[]))!=1:issues.append('missing-or-duplicate:'+stage)
  def t(name):return stages.get(name,[{}])[0].get('time')
  stamp={'planned':planned,**{k:t(k) for k in stages_required}}
  for stage, values in stages.items():
   for row in values:
    if stage in stages_required[:-1] and (not finite(row.get('planned')) or abs(row['planned']-planned)>1e-6):issues.append('planned-identity-mismatch')
  for key,a,b in [('planned_to_intent','planned','intent'),('planned_to_posted','planned','posted'),('intent_to_posted','intent','posted'),('posted_to_received','posted','received'),('received_to_handler_return','received','handler-return-state')]+([('intent_to_main_enter','intent','main-enter'),('main_enter_to_post_begin','main-enter','post-begin'),('post_begin_to_posted','post-begin','posted')] if revision==2 else ([('intent_to_post_begin','intent','post-begin'),('post_begin_to_entry','post-begin','posted'),('post_entry_to_return','posted','post-return')] if revision==3 else [])):
   if finite(stamp[a]) and finite(stamp[b]):
    delta=stamp[b]-stamp[a];delays[key].append(delta)
    if delta < -(5e-6 if revision==3 and a=='planned' else 1e-6):issues.append('non-monotonic-stage')
  if revision>=2:
   origin=report.get('inputWindowStart',{})
   for stage in ('posted','received'):
    for row in stages.get(stage,[]):
     for axis,delta in (('x',s['dx']),('y',s['dy'])):
      if not finite(origin.get(axis)) or not finite(row.get(axis)) or abs(row[axis]-(origin[axis]+delta))>=1:issues.append('coordinate-mismatch:'+stage)
  if revision>=2 and len(stages.get('posted',[]))==len(stages.get('received',[]))==1:
   a,b=stages['posted'][0],stages['received'][0]
   if not all(finite(x.get(axis)) for x in (a,b) for axis in ('x','y')) or math.hypot(a['x']-b['x'],a['y']-b['y'])>=1:issues.append('posted-received-coordinate-mismatch')
  if t('posted') is not None:posted.append(seq)
  if t('received') is not None:received.append(seq)
  if t('handler-return-state') is not None:states.append(stages['handler-return-state'][0])
 # Main AppKit queue protocol preserves posting and receiving order; file order is irrelevant.
 for stage in stages_required:
  ordered=[grouped[slot['sequence']].get(stage,[{}])[0].get('time') for slot in slots]
  if any(finite(a) and finite(b) and b<=a for a,b in zip(ordered,ordered[1:])):issues.append('cross-sequence-order:'+stage)
 if revision>=2:
  posted_times=[grouped[s['sequence']].get('posted',[{}])[0].get('time') for s in slots]
  minimum=.125 if qualification else (.025 if interaction=='ZOOM' else 1/120)
  if any(finite(a) and finite(b) and b-a<minimum-1e-6 for a,b in zip(posted_times,posted_times[1:])):issues.append('posting-minimum-spacing-violated')
 if revision==3:
  for a,b in zip(slots,slots[1:]):
   end=grouped[a['sequence']].get('post-return',[{}])[0].get('time');begin=grouped[b['sequence']].get('post-begin',[{}])[0].get('time')
   if finite(end) and finite(begin) and end>begin+1e-6:issues.append('overlapping-background-posts')
 for a,b in zip(slots,slots[1:]):
  end=grouped[a['sequence']].get('handler-return-state',[{}])[0].get('time');begin=grouped[b['sequence']].get('received',[{}])[0].get('time')
  if finite(end) and finite(begin) and end>begin:issues.append('overlapping-handler-intervals')
 if len(posted)!=report.get('posted') or len(received)!=report.get('received'):issues.append('receipt-count-mismatch')
 missing=sorted(set(posted)-set(received));unsent=sorted(set(grouped)-set(posted))
 if missing:issues.append('posted-not-received')
 if sorted(report.get('unreceived',[]))!=missing:issues.append('missing-accounting-mismatch')
 if sorted(report.get('notPosted',[]))!=unsent:issues.append('unsent-accounting-mismatch')
 if report.get('reason'):issues.append('segment-stopped:'+report['reason'])
 if report.get('overflow'):issues.append('overflow')
 if any(s.get('consumed') is not True for s in states):issues.append('receiver-did-not-own-input')
 limit=plan.get('lateLimit')
 if not finite(limit):issues.append('unknown-late-limit')
 elif delays['planned_to_posted'] and max(delays['planned_to_posted'])>limit+1e-6:issues.append('late-beyond-preregistered-limit')
 # Recompute motion independently; caller's effectiveMotion is not evidence by itself.
 interaction=plan['interaction'];motion=False;trajectory=True;cumulative=0
 state_map={s['sequence']:s for s in states}
 dragging=False
 for slot in slots:
  s=state_map.get(slot['sequence'])
  if interaction=='ZOOM':cumulative+=slot.get('wheel',0)
  if not s:trajectory=False;continue
  if slot['kind']=='drag' and math.hypot(slot['dx'],slot['dy'])>=5:dragging=True
  if revision==3 and interaction in ('NODE','PAN'):
   dx,dy=(slot['dx'],slot['dy']) if dragging else (0,0)
   expected=(dx,-dy) if interaction=='NODE' and slot['kind']!='up' else ((0,0) if interaction=='NODE' else (before['clipX']-dx,before['clipY']+dy))
   actual=(s.get('nodeX'),s.get('nodeY')) if interaction=='NODE' else (s.get('x'),s.get('y'))
   if not all(finite(v) for v in actual) or any(abs(a-b)>1e-6 for a,b in zip(actual,expected)):trajectory=False
  if interaction=='NODE':
   nx,ny=s.get('nodeX'),s.get('nodeY');motion |= finite(nx) and finite(ny) and math.hypot(nx,ny)>5
   expected=(0,0) if slot['kind'] in ('down','up') else (slot['dx'], -slot['dy'])
   # Initial sub-threshold moves are deliberately ignored by production ownership.
   if slot['kind']=='drag' and math.hypot(slot['dx'],slot['dy'])<5 and s==states[0]:continue
   if not finite(nx) or not finite(ny) or abs(nx-expected[0])>5 or abs(ny-expected[1])>5:trajectory=False
  elif interaction=='PAN':
   x,y=s.get('x'),s.get('y');bx,by=before.get('clipX'),before.get('clipY')
   if not all(finite(v) for v in (x,y,bx,by)):trajectory=False;continue
   motion |= max(abs(x-bx),abs(y-by))>5
   if abs(x-(bx-slot['dx']))>5 or abs(y-(by+slot['dy']))>5:trajectory=False
  else:
   z=s.get('zoom');speed=before.get('canvasContext',{}).get('wheelSpeed')
   if not finite(z) or not finite(speed):trajectory=False;continue
   motion |= abs(z-1)>.01
   if z<=.05 or z>=4 or abs(z-(1.1**(cumulative*speed)))>(1e-9 if revision==3 else .02):trajectory=False
 if not motion:issues.append('no-effective-motion')
 elif report.get('effectiveMotion') is not True:issues.append('reported-motion-flag-conflict')
 if not trajectory:issues.append('trajectory-not-verified')
 if slots[-1]['sequence'] not in state_map:issues.append('terminal-state-unobserved')
 if states and slots[-1]['sequence'] in state_map:
  last=state_map[slots[-1]['sequence']]
  if not finite(last.get('zoom')) or not finite(after.get('zoom')) or abs(last['zoom']-after['zoom'])>.001:issues.append('final-zoom-mismatch')
  if interaction in ('PAN','NODE'):
   for axis in ('X','Y'):
    if not finite(after.get('clip'+axis)) or not finite(last.get(axis.lower())) or abs(after['clip'+axis]-last[axis.lower()])>.5:issues.append('final-viewport-mismatch')
 if interaction in ('NODE','PAN'):
  if any(not finite(v) or abs(v-before['zoom'])>.001 for v in [after.get('zoom')]+[s.get('zoom') for s in states]):issues.append('unexpected-zoom-during-nonzoom')
 if revision==3 and interaction in ('PAN','ZOOM'):
  for key in ('canUndo','canRedo'):
   if type(before.get(key)) is not bool or type(after.get(key)) is not bool or before[key]!=after[key]:issues.append('navigation-undo-boundary:'+key)
 if interaction=='NODE':
  if not valid_uuid(before.get('targetNode')) or before.get('targetNode')!=after.get('targetNode'):issues.append('node-target-mismatch')
  if slots[-1]['sequence'] in state_map and not(before.get('canUndo') is False and before.get('canRedo') is True and after.get('canUndo') is True and after.get('canRedo') is False):issues.append('node-undo-boundary')
 observed_node_norms=[math.hypot(v['nodeX'],v['nodeY']) for v in states if finite(v.get('nodeX')) and finite(v.get('nodeY'))]
 return {'planned_early_intents':{'count':sum(v<0 for v in delays['planned_to_intent']),'earliest_us':min(delays['planned_to_intent'],default=0)*1e6},'partial_state_observations':{'handler_states':len(states),'node_max_offset_norm':max(observed_node_norms,default=0),'node_any_nonzero_offset':any(v>1e-6 for v in observed_node_norms),'full_trajectory_verified':trajectory,'terminal_state_observed':slots[-1]['sequence'] in state_map,'reported_motion':report.get('effectiveMotion'),'motion_flag_disagrees':motion != report.get('effectiveMotion')},'interaction':interaction,'qualification':'INVALID' if issues else ('B_LOW_LOAD_ACTION_QUALIFIED' if qualification else 'B_LOCAL_STAGE_EVIDENCE'),
  'issues':sorted(set(issues)),'planned':len(slots),'posted':len(posted),'received':len(received),'unreceived':missing,'not_posted':unsent,
  'delays':{k:distribution(v) for k,v in delays.items()},'motion_recomputed':motion,'trajectory_verified':trajectory,
  'no_claims':['hardware input latency','presented FPS','GPU duration','causal attribution'],
  'pilot':report.get('pilot'),'profile':profile,'protocolRevision':revision,'partial_delays_retained':bool(issues),'phase_meanings':'v3 posted is background postEvent entry; post-return may follow main receive; up to 5us planned-clock quantization retained. v2 posted immediately precedes NSApp.postEvent; v1 posted includes construction','geometry_join':'unjoined callbacks; no layout-completion latency inferred','zoom_anchor':'not independently qualified by handler-return samples'}
def main():
 p=argparse.ArgumentParser();p.add_argument('prefix',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();base=str(a.prefix)
 completion=Path(base+'-completion.json')
 result=analyze(json.loads(Path(base+'.json').read_text()),json.loads(Path(base+'-plan.json').read_text()),json.loads(Path(base+'-events.json').read_text()),json.loads(completion.read_text()) if completion.exists() else None)
 a.output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
if __name__=='__main__':main()
