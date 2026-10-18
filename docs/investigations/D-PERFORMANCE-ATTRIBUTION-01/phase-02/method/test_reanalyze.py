import csv, json, sqlite3, tempfile, unittest
from pathlib import Path
from reanalyze import RefStore, stream_rows, scheduler_account, classify, analyze, clean, weighted_middle, NS

class MethodTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.store=RefStore(self.root/'refs.sqlite')
    def tearDown(self):
        self.store.close();self.tmp.cleanup()
    def rows(self,xml,schemas=('A','B')):
        p=self.root/'input.xml';p.write_text(xml)
        return list(stream_rows(p,schemas,self.store))
    def test_cross_row_table_nested_and_repeated_tags(self):
        rows=self.rows('''<trace-query-result><node xpath="/run/data/table[2]">
        <row><process id="p"><pid id="pid">7</pid></process><start-time id="t">12</start-time>
        <tagged-backtrace id="bt"><frame id="f" name="symbol"><binary id="b" name="Module"/></frame></tagged-backtrace></row></node>
        <node xpath="/run/data/table[1]"><row><process ref="p"/><start-time ref="t"/><start-time ref="t"/><tagged-backtrace ref="bt"/></row></node></trace-query-result>''')
        self.assertEqual([r[0] for r in rows],['B','A'])
        row=rows[1][2];self.assertEqual(len(row['children']),4)
        self.assertEqual(self.store.number(self.store.child(self.store.child(row,'process'),'pid')),7)
        frame=self.store.resolve(self.store.child(row,'tagged-backtrace')['children'][0])
        self.assertEqual(self.store.child(frame,'binary')['attrs']['name'],'Module')
    def test_missing_and_forward_reference_rejected_at_use(self):
        for ref in ['missing','future']:
            with self.assertRaises(ValueError):self.store.resolve({'ref':ref})
    def test_reference_cycle_rejected(self):
        self.store.put('a',{'ref':'b'});self.store.put('b',{'ref':'a'})
        with self.assertRaises(ValueError):self.store.resolve({'ref':'a'})
    def test_duplicate_id_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.rows('<trace-query-result><node xpath="/table[1]"><row><x id="a">1</x><x id="a">2</x></row></node></trace-query-result>')
    def test_unknown_schema_xpath_rejected(self):
        with self.assertRaises(ValueError):self.rows('<trace-query-result><node xpath="wrong"/></trace-query-result>')
    def test_schema_mismatch_and_index_rejected(self):
        for xml in ['<node xpath="/table[1]"><schema name="wrong"/></node>', '<node xpath="/table[0]"/>','<node xpath="/table[3]"/>']:
            with self.subTest(xml=xml), self.assertRaises(ValueError):self.rows(xml)
    def test_anonymous_addresses_remain_distinct(self):
        self.assertNotEqual(clean('0x123'),clean('0x456'))
        self.assertEqual(clean('0xABC'),clean('0xabc'))
        self.assertNotIn('0x',clean('0x123'))
        self.assertEqual(clean('/Users/private/data'),'<private-path>')
    def test_weighted_middle_is_not_row_middle(self):
        ss=[{'weight_ns':9,'row':1},{'weight_ns':1,'row':2},{'weight_ns':1,'row':3}]
        self.assertEqual(weighted_middle(ss)['row'],1)
    def test_invalid_window_rejected(self):
        with self.assertRaises(ValueError):scheduler_account([],10,10)
    def test_scheduler_all_named_states_and_adjacency(self):
        names=['Running','Runnable','Blocked','Interrupted','Preempted','Unknown','FutureState']
        a=scheduler_account([(i,i+1,s) for i,s in enumerate(names)],0,7)
        self.assertEqual(a['state_union_ns'],dict.fromkeys(names,1))
        self.assertEqual((a['covered_ns'],a['gap_ns'],a['overlap_ns']),(7,0,0))
    def test_scheduler_duplicate_same_and_cross_state_overlap(self):
        a=scheduler_account([(0,5,'Running'),(0,5,'Running'),(3,7,'Running'),(4,8,'Blocked')],0,10)
        self.assertEqual(a['exact_duplicate_intervals'],1)
        self.assertEqual(a['raw_state_sum_ns']['Running'],14)
        self.assertEqual(a['state_union_ns'],{'Running':7,'Blocked':4})
        self.assertEqual((a['covered_ns'],a['gap_ns'],a['overlap_ns'],a['cross_state_overlap_ns']),(8,2,7,3))
    def test_scheduler_boundaries_and_explicit_unknown_not_gap(self):
        a=scheduler_account([(-5,2,'Unknown'),(8,15,'Running'),(10,12,'Blocked'),(5,5,'Running')],0,10)
        self.assertEqual(a['state_union_ns'],{'Unknown':2,'Running':2})
        self.assertEqual(a['gap_ns'],6)
    def test_classification_overlap_and_current_connection_symbols(self):
        rules={'wire':['WorkflowConnectionHitView','WorkflowConnectionReceiver'],'input':['routePointer']}
        self.assertEqual(classify([('D','WorkflowConnectionHitView.routePointer')]*3,rules),['wire','input'])
        self.assertEqual(classify([('D','UnrelatedWirelessStatus')],rules),[])
    def make_fixture(self):
        (self.root/'exports').mkdir();(self.root/'reports').mkdir();(self.root/'out').mkdir();(self.root/'scratch').mkdir()
        phase='03-pan'
        (self.root/'exports'/f'{phase}-toc.xml').write_text('''<trace-toc><run><info><target><process pid="7"/></target></info><data><table schema="time-profile"/><table schema="thread-state"/></data></run></trace-toc>''')
        (self.root/'reports'/f'{phase}-analysis.json').write_text(json.dumps({'window_s':[1.,4.]}))
        # 1ms is not assumed: 2ms+3ms main, 4ms worker; lower-bound included, upper excluded.
        xml='''<trace-query-result><node xpath="/run/data/table[1]">
        <row><sample-time>1000000000</sample-time><process id="p"><pid>7</pid></process><thread id="m" fmt="Main Thread (test)"><tid>1</tid></thread><thread-state>Running</thread-state><weight>2000000</weight><tagged-backtrace id="bt"><frame id="f" name="recur"><binary name="D"/></frame><frame ref="f"/></tagged-backtrace></row>
        <row><sample-time>2000000000</sample-time><process ref="p"/><thread ref="m"/><thread-state>Running</thread-state><weight>3000000</weight><tagged-backtrace><frame name="recur"><binary name="OtherModule"/></frame></tagged-backtrace></row>
        <row><sample-time>3000000000</sample-time><process ref="p"/><thread fmt="worker"><tid>2</tid></thread><thread-state>Running</thread-state><weight>4000000</weight><tagged-backtrace><frame name="0x123"><binary name="D"/></frame></tagged-backtrace></row>
        <row><sample-time>4000000000</sample-time><process ref="p"/><thread ref="m"/><thread-state>Running</thread-state><weight>99000000</weight><tagged-backtrace ref="bt"/></row>
        <row><sample-time>1500000000</sample-time><process><pid>8</pid></process><thread fmt="Main Thread (other)"><tid>1</tid></thread><thread-state>Running</thread-state><weight>99000000</weight><tagged-backtrace ref="bt"/></row>
        <row><sample-time>1500000000</sample-time><process ref="p"/><thread ref="m"/><thread-state>Blocked</thread-state><weight>99000000</weight><tagged-backtrace ref="bt"/></row>
        </node><node xpath="/run/data/table[2]">
        <row><start-time>0</start-time><duration>5000000000</duration><process ref="p"/><thread ref="m"/><thread-state>Running</thread-state></row>
        <row><start-time>0</start-time><duration>5000000000</duration><process ref="p"/><thread fmt="worker"><tid>2</tid></thread><thread-state>Running</thread-state></row>
        </node></trace-query-result>'''
        (self.root/'exports'/f'{phase}-data.xml').write_text(xml)
        return phase
    def test_end_to_end_all_threads_weights_recursion_modules_and_half_open(self):
        phase=self.make_fixture();hot,_,timeline,_,result=analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
        self.assertEqual(result['scopes']['all']['sample_weight_ms'],9)
        self.assertEqual(result['scopes']['main']['sample_weight_ms'],5)
        self.assertEqual(result['scopes']['all']['leaf_symbol_status_ms']['unsymbolicated'],4)
        self.assertEqual(sum(x['covered_ns'] for x in result['scheduler'].values()),6*NS)
        main=[h for h in hot if h['thread']=='main' and h['kind']=='inclusive' and h['module']=='D'];self.assertEqual(main[0]['weight_ms'],2)
        self.assertEqual([t['weight_ms'] for t in timeline if t['thread']=='all' and t['period'] in ['early','middle','late']],[2,3,4])
    def test_selection_determinism_and_empty_thirds(self):
        phase=self.make_fixture();analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
        p=self.root/'out'/f'{phase}-selected-stacks.json';first=p.read_bytes()
        analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
        self.assertEqual(p.read_bytes(),first)
        picks=json.loads(first);self.assertFalse(any(s['thread']=='main' and s['period']=='late' for s in picks))
    def test_missing_tid_and_negative_weight_rejected(self):
        phase=self.make_fixture();p=self.root/'exports'/f'{phase}-data.xml';original=p.read_text()
        for content in [original.replace('<tid>1</tid>',''),original.replace('<weight>2000000</weight>','<weight>-1</weight>')]:
            p.write_text(content)
            with self.assertRaises(ValueError):analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
    def test_distinct_tid_with_same_role_does_not_merge(self):
        phase=self.make_fixture();p=self.root/'exports'/f'{phase}-data.xml'
        p.write_text(p.read_text().replace('fmt="worker"','fmt="Main Thread (same name)"'))
        *_,r=analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
        self.assertEqual(r['scopes']['main']['sample_weight_ms'],5)
        self.assertEqual(r['scopes']['main-02']['sample_weight_ms'],4)
    def test_zero_sample_window_keeps_scheduler(self):
        phase=self.make_fixture();p=self.root/'exports'/f'{phase}-data.xml'
        p.write_text(p.read_text().replace('<thread-state>Running</thread-state><weight>','<thread-state>Blocked</thread-state><weight>'))
        *_,r=analyze(self.root,self.root/'out',self.root/'scratch',phase,{})
        self.assertEqual(r['scopes']['all']['sample_weight_ms'],0)
        self.assertEqual(r['scheduler']['main']['gap_ns'],0)

if __name__=='__main__':unittest.main(verbosity=2)
