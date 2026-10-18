#!/usr/bin/env python3
"""Read-only, streaming xctrace XML analysis. No App launch, events, or network.

Use --old-root for Phase 1 exports/reports, --output for small derived files,
--scratch for this process's temporary SQLite reference index. Raw XML never
leaves the supplied local root. Exact PID is read only from the matching TOC.
"""
import argparse, collections, csv, functools, gzip, hashlib, json, math
import random, re, sqlite3, tempfile, xml.etree.ElementTree as ET
from pathlib import Path

SEED = 20261018
PHASES = ['02-node-drag-repeat', '03-pan', '05-wheel-zoom-repeat',
          '06-idle-current', '07-left-hidden-wheel']
NS = 1_000_000_000


def clean(s):
    s = re.sub(r'/Users/[^\s)]+|/Volumes/[^\s)]+', '<private-path>', s)
    # Keep different unsymbolicated addresses distinct without publishing addresses.
    return re.sub(r'0x[0-9A-Fa-f]+', lambda m: '<address-' + hashlib.sha256(m[0].lower().encode()).hexdigest()[:16] + '>', s)


class RefStore:
    """Disk-backed definitions, bounded decoded cache; no full XML DOM."""
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute('PRAGMA journal_mode=OFF')
        self.db.execute('CREATE TABLE definitions (id TEXT PRIMARY KEY, value TEXT)')
        self.get = functools.lru_cache(maxsize=8192)(self._get)
        self.definitions = 0
    def put(self, key, value):
        self.db.execute('INSERT INTO definitions VALUES (?,?)',
                        (key, json.dumps(value, separators=(',', ':'))))
        self.definitions += 1
    def _get(self, key):
        row = self.db.execute('SELECT value FROM definitions WHERE id=?', (key,)).fetchone()
        if row is None:
            raise ValueError('Unresolved reference: ' + key)
        return json.loads(row[0])
    def resolve(self, value):
        seen = set()
        while value is not None and 'ref' in value:
            key = value['ref']
            if key in seen:
                raise ValueError('Reference cycle')
            seen.add(key)
            value = self.get(key)
        return value
    def child(self, value, tag):
        value = self.resolve(value)
        if value is None:
            return None
        for c in value['children']:
            obj = self.resolve(c)
            if obj['tag'] == tag:
                return obj
        return None
    def text(self, value):
        v = self.resolve(value)
        return v['text'] if v else ''
    def formatted(self, value):
        v = self.resolve(value)
        return v['attrs'].get('fmt', v['text']) if v else '<missing>'
    def number(self, value):
        text = self.text(value)
        return int(text) if text else None
    def close(self):
        self.get.cache_clear()
        self.db.close()


def stream_rows(path, schemas, store):
    """IDs are document-wide, including definitions in nonselected tables.
    Preserve duplicate child tags/order. Fail on duplicate IDs or unresolved refs.
    Keep only current nesting stack plus a disk index, not prior rows.
    """
    stack, elements = [], []
    schema = None
    ordinal = collections.Counter()
    for event, el in ET.iterparse(path, events=('start', 'end')):
        if event == 'start':
            stack.append({'tag': el.tag, 'attrs': dict(el.attrib), 'text': '', 'children': []})
            elements.append(el)
            if el.tag == 'node':
                match = re.search(r'table\[(\d+)\]', el.get('xpath', ''))
                if not match:
                    raise ValueError('Unrecognized table XPath')
                index = int(match.group(1)) - 1
                if not 0 <= index < len(schemas):
                    raise ValueError('Table index outside matching TOC')
                schema = schemas[index]
            if el.tag == 'schema' and el.get('name') != schema:
                raise ValueError('Schema disagrees with matching TOC')
            continue
        value = stack.pop()
        elements.pop()
        value['text'] = el.text or ''
        if 'ref' in value['attrs']:
            token = {'ref': value['attrs']['ref']}
        else:
            ident = value['attrs'].pop('id', None)
            if ident is not None:
                store.put(ident, value)
                token = {'ref': ident}
            else:
                token = value
        if el.tag == 'row':
            ordinal[schema] += 1
            yield schema, ordinal[schema], value
        elif stack and stack[-1]['tag'] not in ('node', 'trace-query-result'):
            stack[-1]['children'].append(token)
        el.clear()
        if elements:
            elements[-1].remove(el)


def scheduler_account(intervals, lo, hi):
    """Exact integer-ns sweep; keep all states, duplicates, gaps and overlaps."""
    if hi <= lo:
        raise ValueError('Invalid analysis window')
    raw, events = collections.Counter(), collections.defaultdict(collections.Counter)
    seen, duplicates = set(), 0
    for start, end, state in intervals:
        a, b = max(start, lo), min(end, hi)
        if b <= a:
            continue
        raw[state] += b-a
        key = (a, b, state)
        if key in seen:
            duplicates += 1
        seen.add(key)
        events[a][state] += 1
        events[b][state] -= 1
    active, union = collections.Counter(), collections.Counter()
    covered = overlap = cross = 0
    prev = lo
    for time in sorted(set(events) | {lo, hi}):
        duration = time-prev
        states = [s for s, count in active.items() if count > 0]
        if states:
            covered += duration
            for state in states:
                union[state] += duration
        if sum(active.values()) > 1:
            overlap += duration
        if len(states) > 1:
            cross += duration
        active.update(events[time])
        prev = time
    return {'window_ns': hi-lo, 'covered_ns': covered, 'gap_ns': hi-lo-covered,
            'overlap_ns': overlap, 'cross_state_overlap_ns': cross,
            'exact_duplicate_intervals': duplicates, 'state_union_ns': dict(union),
            'raw_state_sum_ns': dict(raw)}


def weighted_middle(samples):
    """First time-ordered sample whose cumulative weight reaches half the bin."""
    half = sum(s['weight_ns'] for s in samples) / 2
    cumulative = 0
    for sample in samples:
        cumulative += sample['weight_ns']
        if cumulative >= half:
            return sample
    raise ValueError('Empty sample list')


def classify(frames, rules):
    return [category for category, needles in rules.items()
            if any(needle in name for _, name in frames for needle in needles)]


def rank_rows(counter):
    total = sum(counter.values())
    cumulative = 0
    for rank, (key, weight) in enumerate(sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])), 1):
        cumulative += weight
        yield rank, key, weight, cumulative/total if total else 0


def csvwrite(path, fields, rows):
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


def analyze(old, output, scratch, phase, rules):
    toc = ET.parse(old/'exports'/f'{phase}-toc.xml')
    schemas = [t.get('schema') for t in toc.findall('.//run/data/table')]
    target = toc.find('.//target/process')
    pid = int(target.get('pid'))
    prior = json.loads((old/'reports'/f'{phase}-analysis.json').read_text())
    lo, hi = [round(x*NS) for x in prior['window_s']]
    if hi <= lo:
        raise ValueError('Invalid analysis window')
    # Preserve the original window, do not find a new "busy" start from CPU data.
    intervals, threads, samples, presentation = collections.defaultdict(list), {}, [], {}
    alias_ids = {}
    def thread_alias(store, row):
        t = store.child(row, 'thread')
        identity = store.number(store.child(t, 'tid'))
        if identity is None:
            raise ValueError('Missing thread identity')
        if identity not in alias_ids:
            fmt = store.formatted(t)
            role = ('main' if fmt.startswith('Main Thread') else
                    'event' if 'NSEventThread' in fmt else 'worker')
            count = sum(a == role or a.startswith(role+'-') for a in alias_ids.values())
            alias_ids[identity] = role if role != 'worker' and count == 0 else f'{role}-{count+1:02}'
        return alias_ids[identity]
    with tempfile.TemporaryDirectory(prefix='phase2-ref-', dir=scratch) as tmp:
        store = RefStore(Path(tmp)/'refs.sqlite')
        counts = collections.Counter()
        try:
            for schema, rowno, row in stream_rows(old/'exports'/f'{phase}-data.xml', schemas, store):
                counts[schema] += 1
                process = store.child(row, 'process')
                row_pid = store.number(store.child(process, 'pid')) if process else None
                if schema in ('hitches-updates','hitches-frame-lifetimes','hitches-renders',
                              'display-surface-swap','displayed-surfaces-interval','metal-command-buffer-completed'):
                    p = presentation.setdefault(schema, {'rows':0,'target_pid_rows':0,'no_pid_rows':0,'fields':[]})
                    p['rows'] += 1
                    p['target_pid_rows'] += int(row_pid == pid)
                    p['no_pid_rows'] += int(row_pid is None)
                    if not p['fields']:
                        p['fields'] = [store.resolve(c)['tag'] for c in row['children']]
                if row_pid != pid or schema not in ('time-profile','thread-state'):
                    continue
                alias = thread_alias(store, row)
                if schema == 'thread-state':
                    start = store.number(store.child(row,'start-time'))
                    duration = store.number(store.child(row,'duration'))
                    if start is None or duration is None or duration < 0:
                        raise ValueError('Invalid scheduler interval')
                    if start < hi and start+duration > lo:
                        intervals[alias].append((start,start+duration,store.formatted(store.child(row,'thread-state'))))
                    continue
                time = store.number(store.child(row,'sample-time'))
                if time is None:
                    raise ValueError('Missing sample timestamp')
                if not lo <= time < hi or store.formatted(store.child(row,'thread-state')) != 'Running':
                    continue
                weight = store.number(store.child(row,'weight'))
                if weight is None or weight < 0:
                    raise ValueError('Missing or negative sample weight')
                bt = store.child(row,'tagged-backtrace')
                frames = []
                for child in (bt['children'] if bt else []):
                    frame = store.resolve(child)
                    binary = store.child(frame,'binary')
                    module = clean(binary['attrs'].get('name','<unknown-binary>')) if binary else '<unknown-binary>'
                    name = clean(frame['attrs'].get('name','<missing-symbol>'))
                    frames.append((module,name))
                if not frames:
                    frames = [('<unknown-binary>','<missing-stack>')]
                # Target-only, symbolized sample index is small and held once, not another raw XML copy.
                samples.append({'row':rowno,'t_ns':time,'weight_ns':weight,'thread':alias,'frames':tuple(frames)})
            definitions = store.definitions
        finally:
            store.close()
    samples.sort(key=lambda s:(s['t_ns'],s['row']))
    scopes = ['all']+sorted(set(intervals)|{s['thread'] for s in samples})
    hot, classrows, timerows, schedulerrows, summaries, selected, trees = [],[],[],[],{},[],{}
    rng = random.Random(SEED)
    split = [lo,lo+(hi-lo)//3,lo+2*(hi-lo)//3,hi]
    periods = [('whole',lo,hi)]+[(name,split[i],split[i+1]) for i,name in enumerate(['early','middle','late'])]
    bins = [('bin-%02d'%i,lo+i*NS,min(hi,lo+(i+1)*NS)) for i in range(math.ceil((hi-lo)/NS))]
    for scope in scopes:
        ss = [s for s in samples if scope=='all' or s['thread']==scope]
        leaf = collections.Counter(); inc=collections.Counter(); modules=collections.Counter()
        categories=collections.Counter(); leafpartition=collections.Counter(); stackweights=collections.Counter()
        for sample in ss:
            frames=sample['frames'];weight=sample['weight_ns']/1e6
            leaf[frames[0]]+=weight;modules[frames[0][0]]+=weight
            for frame in set(frames): inc[frame]+=weight
            cats=classify(frames,rules)
            for cat in cats: categories[cat]+=weight
            own=classify([frames[0]],rules)
            leafpartition['+'.join(sorted(own)) if own else 'UNCLASSIFIED']+=weight
            stackweights[frames]+=weight
        total=sum(leaf.values())
        symbol_status=collections.Counter()
        for (_,name),weight in leaf.items():
            state=('deduplicated' if 'deduplicated_symbol' in name else 'unsymbolicated' if '<address-' in name or name.startswith('<missing') else 'named')
            symbol_status[state]+=weight
        summaries[scope]={'sample_weight_ms':total,'sample_count':len(ss),'leaf_module_ms':dict(modules),
                          'leaf_symbol_status_ms':dict(symbol_status),'leaf_class_partition_ms':dict(leafpartition),
                          'inclusive_class_ms_overlapping':dict(categories),
                          'top_self':[{'module':k[0],'symbol':k[1],'ms':v} for _,k,v,_ in list(rank_rows(leaf))[:20]]}
        for kind,counter in [('self',leaf),('inclusive',inc)]:
            for rank,(module,symbol),weight,cumulative in rank_rows(counter):
                hot.append(dict(phase=phase,thread=scope,kind=kind,rank=rank,module=module,symbol=symbol,
                                weight_ms=weight,cumulative_fraction_of_ranked_weights=cumulative,
                                denominator_ms=total))
        for cat,weight in categories.items():classrows.append(dict(phase=phase,thread=scope,kind='inclusive_overlapping',category=cat,weight_ms=weight,denominator_ms=total))
        for cat,weight in leafpartition.items():classrows.append(dict(phase=phase,thread=scope,kind='leaf_exclusive_partition',category=cat,weight_ms=weight,denominator_ms=total))
        for period,a,b in periods+bins:
            ps=[s for s in ss if a<=s['t_ns']<b]
            groups=collections.Counter()
            for sample in ps:
                for cat in classify(sample['frames'],rules):groups[cat]+=sample['weight_ns']/1e6
            timerows.append(dict(phase=phase,thread=scope,period=period,start_s=a/NS,end_s=b/NS,
                                 weight_ms=sum(s['weight_ns'] for s in ps)/1e6,samples=len(ps),
                                 classes_json=json.dumps(groups,sort_keys=True)))
        # Every thread/third: maximum aggregate leaf representative + seeded uniform row.
        if scope!='all':
            for period,a,b in periods[1:]:
                ps=[s for s in ss if a<=s['t_ns']<b]
                if not ps:continue
                dominant=collections.Counter()
                for s in ps:dominant[s['frames'][0]]+=s['weight_ns']
                winner=sorted(dominant,key=lambda k:(-dominant[k],k))[0]
                picks=[('dominant-leaf',next(s for s in ps if s['frames'][0]==winner)),('seeded-uniform',rng.choice(ps))]
                for rule,s in picks:selected.append({'phase':phase,'thread':scope,'period':period,'selection':rule,'row':s['row'],'t_s':s['t_ns']/NS,'weight_ms':s['weight_ns']/1e6,'frames':s['frames']})
            if ss:
                binweights=collections.Counter()
                for s in ss:binweights[(s['t_ns']-lo)//NS]+=s['weight_ns']
                winner=sorted(binweights,key=lambda k:(-binweights[k],k))[0]
                ps=[s for s in ss if (s['t_ns']-lo)//NS==winner]
                # Weighted median-in-time sample inside the highest-work bin, independent of keywords.
                s=weighted_middle(ps)
                selected.append({'phase':phase,'thread':scope,'period':f'bin-{winner:02}','selection':'highest-work-bin-weighted-middle-sample','row':s['row'],'t_s':s['t_ns']/NS,'weight_ms':s['weight_ns']/1e6,'frames':s['frames']})
        # Complete exported symbol-path histogram. Deduplicated symbols are not recoverable.
        if scope!='all':
            trees[scope]=[{'weight_ms':v,'leaf_to_root':k} for k,v in sorted(stackweights.items(),key=lambda kv:(-kv[1],kv[0]))]
    accounts={}
    for thread,ivals in sorted(intervals.items()):
        account=scheduler_account(ivals,lo,hi);accounts[thread]=account
        for state in sorted(account['state_union_ns']):
            schedulerrows.append(dict(phase=phase,thread=thread,state=state,raw_sum_s=account['raw_state_sum_ns'][state]/NS,union_s=account['state_union_ns'][state]/NS,
                                      window_s=(hi-lo)/NS,covered_s=account['covered_ns']/NS,gap_s=account['gap_ns']/NS,overlap_s=account['overlap_ns']/NS,
                                      cross_state_overlap_s=account['cross_state_overlap_ns']/NS,exact_duplicate_intervals=account['exact_duplicate_intervals']))
    result={'phase':phase,'window_ns':[lo,hi],'seed':SEED,'xml_row_counts':counts,'reference_definitions':definitions,
            'window_kind':'Phase 1 requested gesture/cue window; no actual input timestamps',
            'scopes':summaries,'scheduler':accounts,'presentation_inventory':presentation,
            'time_profile_schema':next(t.attrib for t in toc.findall('.//run/data/table') if t.get('schema')=='time-profile')}
    (output/f'{phase}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    (output/f'{phase}-selected-stacks.json').write_text(json.dumps(selected,ensure_ascii=False,indent=2)+'\n')
    # Deterministic gzip header; symbols only, no IDs/paths/process information.
    with (output/f'{phase}-call-trees.json.gz').open('wb') as f:
        with gzip.GzipFile(fileobj=f,mode='wb',filename='',mtime=0) as gz:
            gz.write(json.dumps(trees,ensure_ascii=False,separators=(',',':')).encode())
    return hot,classrows,timerows,schedulerrows,result


def main():
    p=argparse.ArgumentParser();p.add_argument('--old-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--scratch',type=Path,required=True);p.add_argument('--rules',type=Path,required=True);p.add_argument('--phases',nargs='+',default=PHASES)
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True);args.scratch.mkdir(parents=True,exist_ok=True)
    rules=json.loads(args.rules.read_text())['patterns'];aggregates=[[],[],[],[]];summary=[]
    for phase in args.phases:
        if phase not in PHASES:raise ValueError('Only predefined valid/qualified legacy phases supported')
        *rows,result=analyze(args.old_root,args.output,args.scratch,phase,rules)
        for dest,rr in zip(aggregates,rows):dest.extend(rr)
        summary.append({'phase':phase,'main':result['scopes'].get('main'),'all_weight_ms':result['scopes']['all']['sample_weight_ms'],'main_scheduler':result['scheduler'].get('main')})
        print(json.dumps({'phase':phase,'all_ms':summary[-1]['all_weight_ms'],'main_ms':result['scopes'].get('main',{}).get('sample_weight_ms'),'states':result['scheduler'].get('main',{}).get('state_union_ns')},ensure_ascii=False),flush=True)
    for filename,rows in zip(['global-hotspots.csv','classification-coverage.csv','timeline.csv','scheduler-accounting.csv'],aggregates):
        csvwrite(args.output/filename,list(rows[0]) if rows else [],rows)
    (args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':main()
