#!/bin/bash
# Fails if a Mach-O in the app's Contents/MacOS still carries a debug-map entry (nm -ap shows " OSO ") or the string
# "/Users/", i.e. a path from the machine that built it. Usage: scripts/check-stripped.sh build/yabbistir.app
set -euo pipefail
# grep -c, not grep -q: with -q grep quits early, nm/strings die of SIGPIPE and pipefail would hide the match.
APP="${1:?usage: check-stripped.sh <app>}"
bad=0
for bin in "$APP"/Contents/MacOS/*; do
    [ -f "$bin" ] || continue
    if [ "$(nm -ap "$bin" 2>/dev/null | grep -c ' OSO ' || true)" != 0 ]; then
        echo "error: $bin has debug-map (OSO) entries" >&2
        bad=1
    fi
    if [ "$(strings -a "$bin" | grep -cF "/Users/" || true)" != 0 ]; then
        echo "error: $bin contains the string \"/Users/\"" >&2
        bad=1
    fi
done
exit $bad
