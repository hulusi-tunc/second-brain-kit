#!/bin/bash
# Nightly: the day's Claude Code sessions and git commits under PROJECTS_DIR into raw/<day>-work.md.
# By hand: bin/brain-work.sh [YYYY-MM-DD]
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" work
DAY="${1:-$(date +%Y-%m-%d)}"
cd "$SB" || exit 1
brain_paused && { brain_log "work: paused for a usage limit"; exit 0; }
OUTF="raw/$DAY-work.md"
[ -f "$OUTF" ] && { brain_log "work: $OUTF exists, skipped"; exit 0; }
MAT=$(python3 "$SB/bin/brain-work-extract.py" "$DAY")
[ "$(echo "$MAT" | grep -c '^## ')" -eq 0 ] && { brain_log "work: nothing on $DAY"; brain_ok; exit 0; }
PROMPT="$(sed "s/<day>/$DAY/" prompts/work-digest.md)"
for try in 1 2; do
  OUT=$(echo "$MAT" | "$CLAUDE" -p "$PROMPT" --tools "" --output-format text 2>&1); RC=$?
  [ $RC -eq 0 ] && echo "$OUT" | grep -q "^# Work" && break
  brain_check_limit "$OUT" && exit 1
  [ $try -eq 1 ] && sleep 120
done
OUT=$(echo "$OUT" | sed -n '/^# Work/,$p')
[ -z "$OUT" ] && { brain_fail "work digest failed for $DAY"; exit 1; }
printf '%s\n' "$OUT" > "$OUTF"
brain_ok
git add "$OUTF" && git commit -q -m "raw: work digest $DAY" && brain_push && brain_log "work: $OUTF written"
