#!/usr/bin/env python3
"""Generate dedicated review build inputs outside the checkout, before normal signing."""
import argparse
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--signing-config', type=Path, required=True)
parser.add_argument('--development-resources', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
output = args.output.resolve()
assert str(output).startswith('/Volumes/'), 'Use an isolated external evidence directory'
assert args.signing_config.is_file() and args.development_resources.is_dir()
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((repo / 'D/Info.plist').read_bytes())
info['DReviewLaunchMode'] = 'isolated-download-v1'
# A review artifact must not advertise itself as the preferred project opener.
for document_type in info.get('CFBundleDocumentTypes', []):
    document_type['LSHandlerRank'] = 'None'
info_path = output / 'ReviewOnly-Info.plist'
info_path.write_bytes(plistlib.dumps(info))
config = output / 'review-signing.xcconfig'
config.write_text('#include "' + str(args.signing_config.resolve()) + '"\n'
                  '#include "' + str(repo / 'D/ReviewOnly.xcconfig') + '"\n'
                  'D_REVIEW_INFO_PLIST = ' + str(info_path) + '\n'
                  'D_DEVELOPMENT_RESOURCES = ' + str(args.development_resources.resolve()) + '\n')
print(config)
