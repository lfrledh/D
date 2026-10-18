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
  r,p,rows=self.fixture();r['effectiveMotion']=False;self.assertIn('no-effective-motion',analyze(r,p,rows)['issues'])
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
if __name__=='__main__':unittest.main()
