#!/usr/bin/env python3
"""Validate normalized report metadata only, not native authenticity or causality."""
import json, sys
from pathlib import Path
from validate_evidence import validate_capture, validate_coverage
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]
errors=[]
for line in (root/'capture-manifest.jsonl').read_text().splitlines():
    item=json.loads(line)
    errors += [item['capture_id']+': '+e for e in validate_capture(item)]
errors += validate_coverage(json.loads((root/'hypothesis-coverage.json').read_text()))
print(json.dumps({'status':'INVALID' if errors else 'MANIFEST_CHECKS_PASSED','errors':errors},indent=2))
sys.exit(bool(errors))
