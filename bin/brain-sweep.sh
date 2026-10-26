#!/bin/bash
# Daily: documents from INBOX_DIR into raw/ (brain-sweep.py), commit.
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" sweep
cd "$SB" || exit 1
OUT=$(python3 "$SB/bin/brain-sweep.py" 2>&1) || { brain_fail "sweep: $OUT"; exit 1; }
brain_log "sweep: $OUT"; brain_ok
git add raw/ && { git diff --cached --quiet || git commit -q -m "raw: inbox sweep"; } && brain_push
