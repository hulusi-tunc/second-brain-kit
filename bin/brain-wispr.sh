#!/bin/bash
# Daily: finished Wispr Flow meetings into raw/ (wispr-sync.py), commit.
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" wispr
cd "$SB" || exit 1
OUT=$(python3 "$SB/bin/wispr-sync.py" 2>&1) || { brain_fail "wispr: $(echo "$OUT" | tail -1)"; exit 1; }
brain_log "wispr: $OUT"; brain_ok
git add raw/ && { git diff --cached --quiet || git commit -q -m "raw: wispr meetings"; } && brain_push
