#!/usr/bin/env python3
"""Offline, allowlisted export of engineering-04 records. Never opens an App.

Input is the controlled private replay directory; output contains only relative
times, slot numbers, timing distributions and qualification results. Source and
binary provenance must be joined separately using the sealed launch receipts.
"""
import argparse
import csv
import json
from pathlib import Path

from replay_analysis import analyze


def export(root, output):
    output.mkdir(parents=True, exist_ok=True)
    summaries, metrics, timeline = [], [], []
    for index in range(6, 18):
        interaction = {6: 'NODE', 7: 'PAN', 8: 'ZOOM', 9: 'PAN', 10: 'ZOOM',
                       11: 'PAN', 12: 'NODE', 13: 'PAN', 14: 'ZOOM', 15: 'NODE',
                       16: 'PAN', 17: 'ZOOM'}[index]
        name = f'replay-{index:02d}-{interaction}'
        def read(suffix):
            return json.loads((root / (name + suffix + '.json')).read_text())
        report, plan, rows, completion = (read(s) for s in ('', '-plan', '-events', '-completion'))
        result = analyze(report, plan, rows, completion)
        # analyze returns no user content or absolute process/scene identities.
        result.update(capture=name, capture_seconds=report['finished'] - report['captureStart'])
        posts = [r for r in rows if r['stage'] == 'posted']
        result['input_span_seconds'] = posts[-1]['time'] - posts[0]['time'] if posts else None
        result['condition'] = ('baseline-Onone' if index <= 9 else 'sampler-contaminated-Onone'
                               if index <= 11 else 'baseline-O' if index <= 14 else 'combined-experiment-Onone')
        result['stop_reason'] = report['reason']
        summaries.append(result)
        for stage, values in result.get('delays', {}).items():
            metrics.append(dict(capture=name, condition=result['condition'], interaction=interaction,
                                qualification=result['qualification'], stage=stage, **values))
        for row in rows:
            timeline.append(dict(capture=name, sequence=row['sequence'], stage=row['stage'],
                                 time_from_epoch_ms=(row['time'] - report['epoch']) * 1000,
                                 planned_from_epoch_ms=(row['planned'] - report['epoch']) * 1000
                                 if isinstance(row.get('planned'), (int, float)) else ''))
    (output / 'engineering-04-summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
    for name, records, fields in (
        ('engineering-04-metrics.csv', metrics,
         ['capture', 'condition', 'interaction', 'qualification', 'stage', 'n', 'p50_ms', 'p95_ms', 'max_ms']),
        ('engineering-04-timeline.csv', timeline,
         ['capture', 'sequence', 'stage', 'time_from_epoch_ms', 'planned_from_epoch_ms']),
    ):
        with (output / name).open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(records)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('private_root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    export(args.private_root, args.output)
