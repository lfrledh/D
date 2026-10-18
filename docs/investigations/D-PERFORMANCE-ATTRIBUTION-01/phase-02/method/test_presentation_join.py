import unittest
from presentation_join import join_records, is_unique_chain
class JoinTests(unittest.TestCase):
 def test_two_swaps_one_interval_is_not_unique_chain(self):
  r=join_records([dict(swap=1,surface=2)],[dict(swap=1,surface=2,time=t) for t in [10,20]],[dict(surface=2,time=10)])[0]
  self.assertEqual(r['displayed_matches'],1);self.assertFalse(is_unique_chain(r))
 def test_exact_time_and_surface_only_no_nearest_matching(self):
  u=[dict(swap=1,surface=2)]
  self.assertEqual(join_records(u,[dict(swap=1,surface=2,time=10)],[dict(surface=2,time=11)])[0]['displayed_matches'],0)
 def test_duplicate_swap_and_display_remain_ambiguous(self):
  u=[dict(swap=1,surface=2)]
  r=join_records(u,[dict(swap=1,surface=2,time=10)]*2,[dict(surface=2,time=10)]*2)[0]
  self.assertEqual((r['swap_matches'],r['displayed_matches'],r['swap_time_ns']),(2,4,None))
 def test_nested_levels_are_not_silently_discarded(self):
  u=[dict(swap=1,surface=2,level=l) for l in [0,1]]
  r=join_records(u,[dict(swap=1,surface=2,time=10)],[dict(surface=2,time=10)])
  self.assertEqual([x['level'] for x in r],[0,1]);self.assertTrue(all(x['displayed_matches']==1 for x in r))
if __name__=='__main__':unittest.main()
