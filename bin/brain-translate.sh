#!/bin/bash
# Nightly: raw/ into wiki/ (prompts/translate.md), move to archive/, commit, push.
# By hand: bin/brain-translate.sh
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" translate
cd "$SB" || exit 1
brain_paused && { brain_log "translate: paused for a usage limit"; exit 0; }
brain_pull
N=$(find raw -type f ! -name .gitkeep | wc -l | tr -d ' ')
[ "$N" -eq 0 ] && { brain_log "translate: raw/ empty"; brain_ok; exit 0; }
brain_log "translate: $N files"
OUT=$("$CLAUDE" -p "Read .claude/commands/translate.md and do exactly what it says against raw/. Do not push. Reply with the changed wiki entries and anything unsure." \
  --output-format text \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash(git add:*),Bash(git commit:*),Bash(git mv:*),Bash(git status:*),Bash(mv:*),Bash(mkdir:*),Bash(ls:*),Bash(python3 -c:*)" \
  < /dev/null 2>&1)
RC=$?; echo "$OUT" | tail -20 >> "$LOG"
if [ $RC -ne 0 ]; then brain_check_limit "$OUT" || brain_fail "translate failed, exit $RC"; exit 1; fi
brain_ok
brain_push && brain_log "translate: done"
