#!/usr/bin/env python3
"""Offline record joins only. Never computes FPS or input-to-display latency."""
import argparse, collections, hashlib, json, tempfile, xml.etree.ElementTree as ET
from pathlib import Path
from reanalyze import RefStore, stream_rows, NS
KEEP={'hitches-updates','hitches-frame-lifetimes','display-surface-swap','displayed-surfaces-interval'}


def join_records(updates, swaps, displayed):
    byswap=collections.defaultdict(list);bydisplay=collections.defaultdict(list)
    for s in swaps:byswap[(s['swap'],s['surface'])].append(s)
    for d in displayed:bydisplay[(d['time'],d['surface'])].append(d)
    out=[]
    for u in updates:
        ss=byswap[(u['swap'],u['surface'])]
        dd=[d for s in ss for d in bydisplay[(s['time'],s['surface'])]]
        out.append(dict(u,swap_matches=len(ss),displayed_matches=len(dd),swap_time_ns=ss[0]['time'] if len(ss)==1 else None))
    return out


def is_unique_chain(row):
    return row['swap_matches'] == 1 and row['displayed_matches'] == 1


def analyze(root, scratch, phase):
    toc=ET.parse(root/'exports'/f'{phase}-toc.xml');schemas=[t.get('schema') for t in toc.findall('.//run/data/table')]
    pid=int(toc.find('.//target/process').get('pid'))
    recording_ns=round(float(toc.findtext('.//run/info/summary/duration'))*NS)
    lo,hi=[round(t*NS) for t in json.loads((root/'reports'/f'{phase}-analysis.json').read_text())['window_s']]
    rows=collections.defaultdict(list)
    with tempfile.TemporaryDirectory(dir=scratch,prefix='display-refs-') as tmp:
        st=RefStore(Path(tmp)/'refs.sqlite')
        try:
            for schema,rowno,row in stream_rows(root/'exports'/f'{phase}-data.xml',schemas,st):
                if schema not in KEEP:continue
                cells=[st.resolve(c) for c in row['children']]
                def n(i):return st.number(cells[i])
                if schema=='hitches-updates':
                    if len(cells)!=9:raise ValueError('updates schema column count')
                    if st.number(st.child(cells[2],'pid'))!=pid:continue
                    rows[schema].append(dict(row=rowno,time=n(0),duration=n(1),display=st.text(cells[3]),swap=n(4),surface=n(5),level=n(7)))
                elif schema=='display-surface-swap':
                    if len(cells)!=16:raise ValueError('swap schema column count')
                    rows[schema].append(dict(time=n(0),swap=n(5),surface=n(3)))
                elif schema=='displayed-surfaces-interval':
                    if len(cells)!=16:raise ValueError('displayed schema column count')
                    rows[schema].append(dict(time=n(0),duration=n(1),surface=n(5)))
                else:
                    if len(cells)!=8:raise ValueError('lifetime schema column count')
                    rows[schema].append(dict(time=n(0),duration=n(1),swap=n(3),surface=n(4)))
        finally:st.close()
    uu=rows['hitches-updates'];joined=join_records(uu,rows['display-surface-swap'],rows['displayed-surfaces-interval'])
    periods=[('whole_recording',None,None),('requested_window',lo,hi)]+[(name,lo+i*(hi-lo)//3,lo+(i+1)*(hi-lo)//3) for i,name in enumerate(['early','middle','late'])]
    results=[]
    for name,a,b in periods:
        ss=[u for u in joined if a is None or a<=u['time']<b];top=[u for u in ss if u['level']==0]
        keys={(u['display'],u['swap'],u['surface']) for u in ss}
        results.append(dict(period=name,update_rows=len(ss),distinct_process_display_swap_surface_keys=len(keys),containment_counts=dict(collections.Counter(u['level'] for u in ss)),top_level_rows=len(top),unique_swap_matches=sum(u['swap_matches']==1 for u in top),unique_displayed_matches=sum(is_unique_chain(u) for u in top),swap_outside_requested_window=sum(u['swap_time_ns'] is not None and not lo<=u['swap_time_ns']<hi for u in top)))
    # Surface/swap values and PID remain local. Publish row numbers and times for unresolved joins.
    unmatched=[{k:u[k] for k in ['row','time','duration','level','swap_matches','displayed_matches']} for u in joined if u['level']==0 and (u['swap_matches']!=1 or u['displayed_matches']!=1)]
    long=[{'row':i+1,'time_ns':x['time'],'duration_ns':x['duration']} for i,x in enumerate(rows['hitches-frame-lifetimes']) if x['time']==0 and x['duration']>recording_ns]
    return dict(phase=phase,window_ns=[lo,hi],recording_duration_ns=recording_ns,periods=results,unmatched_top_level=unmatched,long_start_zero_lifetimes=long,status='PROCESS_RECORD_JOIN_ONLY; NOT_WINDOW_OR_CONTENT_ASSOCIATED',fps=None,input_latency=None)


def main():
    p=argparse.ArgumentParser();p.add_argument('--old-root',type=Path,required=True);p.add_argument('--scratch',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    result=[analyze(a.old_root,a.scratch,p) for p in ['02-node-drag-repeat','03-pan','05-wheel-zoom-repeat']]
    a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print('Three legacy record joins complete; no displayed frame metrics calculated')
if __name__=='__main__':main()
