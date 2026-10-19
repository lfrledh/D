import copy, unittest
from replay_analysis import analyze, distribution, expected_slots
class ReplayAuditTests(unittest.TestCase):
 def fixture(self,interaction='PAN'):
  slots=expected_slots(interaction,2)
  p={'interaction':interaction,'activeSeconds':2,'lateLimit':.05 if interaction=='ZOOM' else 1/30,'slots':slots}
  scene={'window':1,'frame':'640x480','scale':2,'screen':'1920x1080','project':'11111111-1111-4111-8111-111111111111','instance':'22222222-2222-4222-8222-222222222222','graph':'33333333-3333-4333-8333-333333333333','targetNode':'44444444-4444-4444-8444-444444444444','nodes':4,'edges':3,'runs':0,'assets':0,'canvasContext':{'wheelSpeed':1},'tool':'hand' if interaction=='PAN' else 'pointer','clipX':100,'clipY':100,'zoom':1,'canUndo':False,'canRedo':True}
  rows=[];cumulative=0
  for slot in slots:
   cumulative+=slot['wheel']
   for j,stage in enumerate(['intent','posted','received','handler-return-state']):
    row={'sequence':slot['sequence'],'stage':stage,'time':10+slot['seconds']+j*.001,'planned':10+slot['seconds'],'consumed':True,'x':100-slot['dx'] if interaction=='PAN' else 100,'y':100+slot['dy'] if interaction=='PAN' else 100,'zoom':1.1**cumulative if interaction=='ZOOM' else 1,'nodeX':slot['dx'] if slot['kind']=='drag' else 0,'nodeY':-slot['dy'] if slot['kind']=='drag' else 0}
    rows.append(row)
  after=copy.deepcopy(scene);after['zoom']=rows[-1]['zoom']
  if interaction=='NODE':after.update(canUndo=True,canRedo=False)
  r={'schema':1,'level':'B_IN_PROCESS_FULL_APP_PENDING_QUALIFICATION','pilot':True,'graphCommitVerified':True,'epoch':10,'captureStart':9,'finished':16,'clock':'systemUptime-seconds','pid':123,'processLaunch':'2026-10-19','executable':'/synthetic/D','bundle':'first-test.D.performance-phase2','source':'9eae90e4adc4008c3894f09bcd07c71e23701045','interaction':interaction,'posted':len(slots),'received':len(slots),'unreceived':[],'notPosted':[],'before':scene,'after':after,'effectiveMotion':True}
  return r,p,rows
 def test_valid_is_only_local_evidence(self):
  a=analyze(*self.fixture());self.assertEqual(a['qualification'],'B_LOCAL_STAGE_EVIDENCE');self.assertIn('presented FPS',a['no_claims'])
 def test_order_independent(self):
  r,p,rows=self.fixture();self.assertEqual(analyze(r,p,rows),analyze(r,p,list(reversed(rows))))
 def test_duplicate_rejected(self):
  r,p,rows=self.fixture();rows.append(rows[0]);self.assertIn('missing-or-duplicate:intent',analyze(r,p,rows)['issues'])
 def test_no_send_no_receive(self):
  r,p,rows=self.fixture();rows=[x for x in rows if x['stage']!='posted'];self.assertIn('missing-or-duplicate:posted',analyze(r,p,rows)['issues'])
 def test_unreceived_accounted(self):
  r,p,rows=self.fixture();rows=[x for x in rows if not(x['stage']=='received' and x['sequence']==1)];self.assertIn('missing-accounting-mismatch',analyze(r,p,rows)['issues'])
 def test_unsent_accounted(self):
  r,p,rows=self.fixture();rows=[x for x in rows if x['sequence']!=2];self.assertIn('unsent-accounting-mismatch',analyze(r,p,rows)['issues'])
 def test_incomplete_invalid(self):
  r,p,rows=self.fixture();rows=rows[:-4];self.assertIn('missing-or-duplicate:posted',analyze(r,p,rows)['issues'])
 def test_stop_retained(self):
  r,p,rows=self.fixture();r['reason']='focus-lost';self.assertIn('segment-stopped:focus-lost',analyze(r,p,rows)['issues'])
 def test_overflow_invalid(self):
  r,p,rows=self.fixture();r['overflow']=True;self.assertIn('overflow',analyze(r,p,rows)['issues'])
 def test_foreign_receiver_invalid(self):
  r,p,rows=self.fixture();rows[-1]['consumed']=False;self.assertIn('receiver-did-not-own-input',analyze(r,p,rows)['issues'])
 def test_effective_motion_required(self):
  r,p,rows=self.fixture();r['effectiveMotion']=False;self.assertIn('reported-motion-flag-conflict',analyze(r,p,rows)['issues']);self.assertEqual(analyze(r,p,rows)['qualification'],'INVALID')
 def test_scene_change_invalid(self):
  r,p,rows=self.fixture();r['after']['window']=2;self.assertIn('scene-changed:window',analyze(r,p,rows)['issues'])
 def test_stage_order_invalid(self):
  r,p,rows=self.fixture();rows[-1]['time']=10;self.assertIn('non-monotonic-stage',analyze(r,p,rows)['issues'])
 def test_late_sender_not_hidden(self):
  r,p,rows=self.fixture();rows[1]['time']=10.1;self.assertIn('late-beyond-preregistered-limit',analyze(r,p,rows)['issues'])
 def test_percentiles_not_fps(self):
  self.assertEqual(distribution([.001,.002,.003]),{'n':3,'p50_ms':2.0,'p95_ms':3.0,'max_ms':3.0})
 def test_missing_intents(self):
  r,p,rows=self.fixture();self.assertIn('missing-or-duplicate:intent',analyze(r,p,[x for x in rows if x['stage']!='intent'])['issues'])
 def test_missing_two_states(self):
  r,p,rows=self.fixture();self.assertIn('missing-or-duplicate:handler-return-state',analyze(r,p,[x for x in rows if x['stage']!='handler-return-state' or x['sequence']==0])['issues'])
 def test_duplicate_plan(self):
  r,p,rows=self.fixture();p['slots'][2]=p['slots'][1];self.assertIn('invalid-plan-identities',analyze(r,p,rows)['issues'])
 def test_false_motion_claim(self):
  r,p,rows=self.fixture()
  for x in rows:x.update(x=100,y=100)
  self.assertIn('no-effective-motion',analyze(r,p,rows)['issues'])
 def test_negative_sequence_stop(self):
  r,p,rows=self.fixture();rows.append({'sequence':-1,'stage':'stopped','time':10.5,'detail':'focus-lost'});self.assertIn('stop-record:focus-lost',analyze(r,p,rows)['issues'])
 def test_unknown_stage(self):
  r,p,rows=self.fixture();rows.append({'sequence':0,'stage':'mystery','time':10.5});self.assertIn('unknown-stage',analyze(r,p,rows)['issues'])
 def test_nan_timestamp(self):
  r,p,rows=self.fixture();rows[0]['time']=float('nan');self.assertIn('invalid-or-out-of-window-time',analyze(r,p,rows)['issues'])
 def test_conflicting_planned(self):
  r,p,rows=self.fixture();rows[0]['planned']=9000;self.assertIn('planned-identity-mismatch',analyze(r,p,rows)['issues'])
 def test_missing_scene_fields(self):
  r,p,rows=self.fixture();r['before'].pop('project');r['after'].pop('project');self.assertIn('missing-scene:project',analyze(r,p,rows)['issues'])
 def test_conflicting_interaction(self):
  r,p,rows=self.fixture();r['interaction']='ZOOM';self.assertIn('interaction-mismatch',analyze(r,p,rows)['issues'])
 def test_unknown_clock(self):
  r,p,rows=self.fixture();r.pop('clock');self.assertIn('unknown-clock',analyze(r,p,rows)['issues'])
 def test_node_positive(self):self.assertEqual(analyze(*self.fixture('NODE'))['qualification'],'B_LOCAL_STAGE_EVIDENCE')
 def test_zoom_positive(self):self.assertEqual(analyze(*self.fixture('ZOOM'))['qualification'],'B_LOCAL_STAGE_EVIDENCE')
 def test_nan_plan_payload(self):
  r,p,rows=self.fixture();p['slots'][1]['dx']=float('nan');self.assertIn('invalid-plan-payload',analyze(r,p,rows)['issues'])
 def test_wrong_plan_kind(self):
  r,p,rows=self.fixture();p['slots'][1]['kind']='wheel';self.assertIn('invalid-plan-payload',analyze(r,p,rows)['issues'])
 def test_boolean_row_id(self):
  r,p,rows=self.fixture();rows[4]['sequence']=True;self.assertIn('invalid-row-identity',analyze(r,p,rows)['issues'])
 def test_reordered_receiving(self):
  r,p,rows=self.fixture()
  for row in rows:
   if row['sequence']==0 and row['stage'] in ('received','handler-return-state'):row['time']+=.1
  self.assertIn('cross-sequence-order:received',analyze(r,p,rows)['issues'])
 def test_invalid_identity(self):
  r,p,rows=self.fixture();r.update(pid=-1,source='unknown');r['before']['project']='';r['after']['project']='';self.assertIn('invalid-scene-identity:project',analyze(r,p,rows)['issues'])
 def test_wrong_protocol(self):
  r,p,rows=self.fixture();r.update(schema=999,level='C_HIDDEN_COMPONENT');self.assertIn('unsupported-record-protocol',analyze(r,p,rows)['issues'])
 def test_pan_graph_changed(self):
  r,p,rows=self.fixture();r['graphCommitVerified']=False;self.assertIn('graph-commit-not-verified',analyze(r,p,rows)['issues'])
 def test_pan_final_view_changed(self):
  r,p,rows=self.fixture();r['after']['clipX']=9999;self.assertIn('final-viewport-mismatch',analyze(r,p,rows)['issues'])
 def test_node_wrong_target(self):
  r,p,rows=self.fixture('NODE');r['after']['targetNode']='';self.assertIn('node-target-mismatch',analyze(r,p,rows)['issues'])
 def test_node_failed_commit(self):
  r,p,rows=self.fixture('NODE');r['graphCommitVerified']=False;self.assertIn('graph-commit-not-verified',analyze(r,p,rows)['issues'])
 def test_zoom_wrong_accumulation(self):
  r,p,rows=self.fixture('ZOOM');rows[7]['zoom']=1;self.assertIn('trajectory-not-verified',analyze(r,p,rows)['issues'])
 def test_zoom_final_mismatch(self):
  r,p,rows=self.fixture('ZOOM');r['after']['zoom']=3;self.assertIn('final-zoom-mismatch',analyze(r,p,rows)['issues'])
 def test_pilot_not_baseline_repeat(self):self.assertTrue(analyze(*self.fixture())['pilot'])
 def test_node_pan_do_not_also_zoom(self):
  for interaction in ('NODE','PAN'):
   with self.subTest(interaction=interaction):
    r,p,rows=self.fixture(interaction);r['after']['zoom']=2
    for row in rows:
     if row['stage']=='handler-return-state':row['zoom']=2
    self.assertIn('unexpected-zoom-during-nonzoom',analyze(r,p,rows)['issues'])

class ReplayQualificationV2Tests(unittest.TestCase):
 def fixture(self,interaction='PAN'):
  old=ReplayAuditTests();r,p,_=old.fixture(interaction)
  p.update(activeSeconds=1.25,lateLimit=.25,profile='qualification-low-load-v1',slots=expected_slots(interaction,1.25,'qualification-low-load-v1'))
  r.update(protocolRevision=2,profile=p['profile'],segment=2,inputWindowStart={'x':210,'y':170},posted=len(p['slots']),received=len(p['slots']))
  r['after']['zoom']=1
  rows=[];cumulative=0
  for slot in p['slots']:
   cumulative+=slot['wheel']
   for j,stage in enumerate(('intent','main-enter','post-begin','posted','received','handler-return-state')):
    row={'sequence':slot['sequence'],'stage':stage,'time':10+slot['seconds']+j*.001,'planned':10+slot['seconds']}
    if stage in ('posted','received'):row.update(x=210+slot['dx'],y=170+slot['dy'])
    if stage=='handler-return-state':row.update(consumed=True,x=100-slot['dx'] if interaction=='PAN' else 100,y=100+slot['dy'] if interaction=='PAN' else 100,zoom=1.1**cumulative if interaction=='ZOOM' else 1,nodeX=slot['dx'] if slot['kind']=='drag' else 0,nodeY=-slot['dy'] if slot['kind']=='drag' else 0)
    rows.append(row)
  rows.append({'sequence':-1,'stage':'sending-ended','time':15.9})
  c={'segment':2,'interaction':interaction,'sendingStopped':True,'resetGraphVerified':True,'reason':None,'time':16.1}
  return r,p,rows,c
 def test_all_three_qualify_only_as_low_load(self):
  for action in ('NODE','PAN','ZOOM'):
   with self.subTest(action=action):self.assertEqual(analyze(*self.fixture(action))['qualification'],'B_LOW_LOAD_ACTION_QUALIFIED')
 def test_profile_cannot_be_mixed(self):
  r,p,rows,c=self.fixture();r['profile']='performance';self.assertIn('profile-mismatch',analyze(r,p,rows,c)['issues'])
 def test_low_load_cannot_claim_old_revision(self):
  r,p,rows,c=self.fixture();r['protocolRevision']=1;self.assertIn('qualification-requires-revision-2',analyze(r,p,rows,c)['issues'])
 def test_exact_slots_required(self):
  r,p,rows,c=self.fixture();p['slots'][1]['dx']=9;self.assertIn('invalid-plan-payload',analyze(r,p,rows,c)['issues'])
 def test_each_new_stage_required(self):
  for stage in ('main-enter','post-begin'):
   with self.subTest(stage=stage):
    r,p,rows,c=self.fixture();self.assertIn('missing-or-duplicate:'+stage,analyze(r,p,[x for x in rows if x['stage']!=stage],c)['issues'])
 def test_coordinate_assertion_both_stages(self):
  for stage in ('posted','received'):
   with self.subTest(stage=stage):
    r,p,rows,c=self.fixture();next(x for x in rows if x['stage']==stage)['x']+=20
    self.assertIn('coordinate-mismatch:'+stage,analyze(r,p,rows,c)['issues'])
 def test_new_stage_inversion(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='main-enter')['time']=10.2
  self.assertIn('non-monotonic-stage',analyze(r,p,rows,c)['issues'])
 def test_late_construction_rejected(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='posted')['time']=10.26
  self.assertIn('late-beyond-preregistered-limit',analyze(r,p,rows,c)['issues'])
 def test_completion_required(self):
  r,p,rows,c=self.fixture();self.assertIn('missing-completion',analyze(r,p,rows)['issues'])
 def test_reset_failure_invalidates_success_report(self):
  r,p,rows,c=self.fixture('NODE');c.update(resetGraphVerified=False,reason='synthetic-reset-failed')
  self.assertIn('reset-not-verified',analyze(r,p,rows,c)['issues'])
 def test_completion_identity_time_stop(self):
  for key,value,issue in [('segment',3,'completion-identity-mismatch'),('time',8,'invalid-completion-time'),('sendingStopped',False,'sending-not-stopped')]:
   with self.subTest(key=key):
    r,p,rows,c=self.fixture();c[key]=value;self.assertIn(issue,analyze(r,p,rows,c)['issues'])
 def test_stop_export_order(self):
  r,p,rows,c=self.fixture();rows[-1]['time']=10.001
  self.assertIn('post-after-sending-ended',analyze(r,p,rows,c)['issues'])
 def test_backlog_retains_local_delay_without_qualifying(self):
  r,p,rows,c=self.fixture();rows=[{'sequence':0,'stage':'intent','time':10.002,'planned':10},{'sequence':0,'stage':'main-enter','time':10.32,'planned':10},{'sequence':1,'stage':'scheduler-stop','time':10.25,'planned':10.25,'detail':'main-delivery-slot-backlog'},{'sequence':-1,'stage':'sending-ended','time':15.9}]
  r.update(posted=0,received=0,notPosted=list(range(6)),reason='main-delivery-slot-backlog');c['reason']=r['reason']
  a=analyze(r,p,rows,c);self.assertEqual(a['qualification'],'INVALID');self.assertTrue(a['partial_delays_retained']);self.assertAlmostEqual(a['delays']['intent_to_main_enter']['max_ms'],318)

 def test_post_receive_distance_is_direct(self):
  r,p,rows,c=self.fixture()
  for row in rows:
   if row['sequence']==0 and row['stage'] in ('posted','received'):row['x']+=.6 if row['stage']=='posted' else -.6
  self.assertIn('posted-received-coordinate-mismatch',analyze(r,p,rows,c)['issues'])
 def test_catch_up_spacing_rejected(self):
  r,p,rows,c=self.fixture()
  for row in rows:
   if row['sequence']==0:row['time']+=.2
  self.assertIn('posting-minimum-spacing-violated',analyze(r,p,rows,c)['issues'])

 def test_diagonal_partial_motion_is_not_erased(self):
  r,p,rows,c=self.fixture('NODE');rows=[x for x in rows if x.get('sequence') in (0,1,-1)]
  state=next(x for x in rows if x.get('sequence')==1 and x['stage']=='handler-return-state');state.update(nodeX=4.301838,nodeY=-3.105829)
  r.update(posted=2,received=2,notPosted=[2,3,4,5],effectiveMotion=False,reason='main-delivery-slot-backlog')
  a=analyze(r,p,rows,c);self.assertEqual(a['qualification'],'INVALID');self.assertTrue(a['partial_state_observations']['node_any_nonzero_offset']);self.assertGreater(a['partial_state_observations']['node_max_offset_norm'],5);self.assertTrue(a['motion_recomputed']);self.assertTrue(a['partial_state_observations']['motion_flag_disagrees'])

 def test_missing_endpoint_is_not_a_mismatched_endpoint(self):
  r,p,rows,c=self.fixture('NODE');last=p['slots'][-1]['sequence'];rows=[x for x in rows if x.get('sequence')!=last]
  r['after'].update(canUndo=False,canRedo=True)
  a=analyze(r,p,rows,c);self.assertEqual(a['qualification'],'INVALID');self.assertIn('terminal-state-unobserved',a['issues']);self.assertNotIn('final-zoom-mismatch',a['issues']);self.assertNotIn('final-viewport-mismatch',a['issues']);self.assertNotIn('node-undo-boundary',a['issues'])



class ContinuousV3Tests(unittest.TestCase):
 def fixture(self,action='PAN'):
  r,p,rows=ReplayAuditTests().fixture(action)
  r.update(protocolRevision=3,profile='performance',segment=6,inputWindowStart={'x':210,'y':170})
  p['profile']='performance';out=[];dragging=False
  for slot in p['slots']:
   if slot['kind']=='drag' and __import__('math').hypot(slot['dx'],slot['dy'])>=5:dragging=True
   group=[x for x in rows if x['sequence']==slot['sequence']]
   for x in group:
    if x['stage'] in ('posted','received'):x.update(x=210+slot['dx'],y=170+slot['dy'])
    if not dragging and x['stage']=='handler-return-state' and action!='ZOOM':x.update(x=100,y=100,nodeX=0,nodeY=0)
   posted=next(x for x in group if x['stage']=='posted')
   out += group+[dict(posted,stage='post-begin'),dict(posted,stage='post-return',time=posted['time']+.0001)]
  out.append({'sequence':-1,'stage':'sending-ended','time':15.9})
  c={'segment':6,'interaction':action,'sendingStopped':True,'resetGraphVerified':True,'resetUndoVerified':True,'reason':None,'time':16.1}
  return r,p,out,c
 def test_three_complete_trajectories(self):
  for a in ('NODE','PAN','ZOOM'):
   with self.subTest(action=a):self.assertEqual(analyze(*self.fixture(a))['qualification'],'B_LOCAL_STAGE_EVIDENCE')
 def test_post_return_not_required_before_receiver(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='post-return')['time']=10.0025
  self.assertEqual(analyze(r,p,rows,c)['issues'],[])
 def test_bridge_return_must_follow_entry(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='post-return')['time']=10
  self.assertIn('non-monotonic-stage',analyze(r,p,rows,c)['issues'])
 def test_each_bridge_stage_required(self):
  for stage in ('post-begin','post-return'):
   with self.subTest(stage=stage):
    r,p,rows,c=self.fixture();self.assertIn('missing-or-duplicate:'+stage,analyze(r,p,[x for x in rows if x['stage']!=stage],c)['issues'])
 def test_five_microsecond_clock_boundary_retains_negative_distribution(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='intent')['time']=9.9999975
  a=analyze(r,p,rows,c);self.assertEqual(a['issues'],[])
  self.assertEqual(a['planned_early_intents']['count'],1)
  self.assertAlmostEqual(a['planned_early_intents']['earliest_us'],-2.5,places=6)
 def test_early_real_send_is_invalid(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='intent')['time']=9.99999
  self.assertIn('non-monotonic-stage',analyze(r,p,rows,c)['issues'])
 def test_small_wrong_motion_not_hidden_by_old_five_point_tolerance(self):
  for action in ('NODE','PAN','ZOOM'):
   with self.subTest(action=action):
    r,p,rows,c=self.fixture(action);state=next(x for x in rows if x['stage']=='handler-return-state' and x['sequence']==20)
    state['zoom' if action=='ZOOM' else 'nodeX' if action=='NODE' else 'x']+=.01
    self.assertIn('trajectory-not-verified',analyze(r,p,rows,c)['issues'])
 def test_duplicate_bridge_return_rejected(self):
  r,p,rows,c=self.fixture();rows.append(next(x for x in rows if x['stage']=='post-return'))
  self.assertIn('missing-or-duplicate:post-return',analyze(r,p,rows,c)['issues'])
 def test_sender_contamination_retains_partial_statistics(self):
  r,p,rows,c=self.fixture();r['reason']=c['reason']='sender-timer-coalesced'
  a=analyze(r,p,rows,c);self.assertEqual(a['qualification'],'INVALID');self.assertGreater(a['delays']['posted_to_received']['n'],0)

 def test_undo_reset_missing_or_failed_rejected(self):
  for value in (None,False):
   with self.subTest(reset=value):
    r,p,rows,c=self.fixture();c['resetUndoVerified']=value
    self.assertIn('reset-undo-not-verified',analyze(r,p,rows,c)['issues'])
 def test_post_begin_cannot_follow_entry(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='post-begin')['time']=10.0015
  self.assertIn('non-monotonic-stage',analyze(r,p,rows,c)['issues'])


 def test_post_return_after_barrier_invalid(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='post-return')['time']=15.95
  self.assertIn('post-return-after-sending-ended',analyze(r,p,rows,c)['issues'])
 def test_background_calls_do_not_overlap(self):
  r,p,rows,c=self.fixture();next(x for x in rows if x['stage']=='post-return')['time']=10.02
  self.assertIn('overlapping-background-posts',analyze(r,p,rows,c)['issues'])
 def test_navigation_must_not_add_or_remove_undo_redo(self):
  for action in ('PAN','ZOOM'):
   for key in ('canUndo','canRedo'):
    with self.subTest(action=action,key=key):
     r,p,rows,c=self.fixture(action);r['after'][key]=not r['before'][key]
     self.assertIn('navigation-undo-boundary:'+key,analyze(r,p,rows,c)['issues'])

if __name__=='__main__':unittest.main()
