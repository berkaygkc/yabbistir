#!/bin/bash
# Fails while StoreConfiguration.publicKeys is empty: with no key no store catalog verifies, so a release built that
# way would have a Store tab that never opens. Usage: scripts/check-store-keys.sh [StoreConfiguration.swift]
set -euo pipefail
FILE="${1:-Packages/YabbistirKit/Sources/YabExtensions/Store/StoreConfiguration.swift}"
[ -f "$FILE" ] || { echo "error: $FILE not found" >&2; exit 1; }
# Comments dropped and the file on one line, so "= [] // none yet" and a list split over lines read the same.
FLAT="$(sed -e 's://.*$::' "$FILE" | tr '\n' ' ')"
if ! grep -Eq 'static let publicKeys[^=]*=' <<< "$FLAT"; then
    echo "error: no StoreConfiguration.publicKeys declaration in $FILE" >&2
    exit 1
fi
if grep -Eq 'static let publicKeys[^=]*=[[:space:]]*\[[[:space:]]*\]' <<< "$FLAT"; then
    echo "error: StoreConfiguration.publicKeys is empty in $FILE; add the store's public keys before a release" >&2
    exit 1
fi
