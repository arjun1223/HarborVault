#!/bin/bash
set -euo pipefail

# Keep signing material out of source and output. Certificates/private keys stay in
# the owner's Keychain; only the selected public certificate identifier is returned.
choice="${HARBOR_SIGNING_IDENTITY:-auto}"
if [ "$choice" != "auto" ]; then
    printf '%s\n' "$choice"
    exit 0
fi
candidates="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ { print $2 }')"
count="$(printf '%s\n' "$candidates" | /usr/bin/awk 'NF { n++ } END { print n+0 }')"
if [ "$count" -gt 1 ]; then
    echo "Multiple development signing identities found. Set HARBOR_SIGNING_IDENTITY to select the same identity for every local build." >&2
    exit 1
elif [ "$count" -eq 1 ]; then
    printf '%s\n' "$candidates"
else
    echo "No development signing identity available. Using ad-hoc signing; updates may require Keychain permissions again." >&2
    printf '%s\n' '-'
fi
