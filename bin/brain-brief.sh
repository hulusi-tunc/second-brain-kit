#!/bin/bash
# Morning: prompts/brief.md into data/brief.md and one notification with the day's one thing.
# Tools beyond the repo (calendar, mail, chat) come from BRIEF_TOOLS in brain.config.
# By hand: bin/brain-brief.sh
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" brief
cd "$SB" || exit 1
brain_paused && { brain_log "brief: paused for a usage limit"; exit 0; }
brain_pull
TODAY=$(date +%Y-%m-%d)
HEALTH=$(brain_health_line)
TOOLS="Read,Glob,Grep,Write${BRIEF_TOOLS:+,ToolSearch,$BRIEF_TOOLS}"
# every Slack workspace added with `brain slack add`, whole server allowed (it is read-only)
for n in $SLACK_WORKSPACES; do TOOLS="$TOOLS,mcp__slack-$n"; done
[ -n "$SLACK_WORKSPACES" ] && [[ "$TOOLS" != *ToolSearch* ]] && TOOLS="$TOOLS,ToolSearch"
OUT=$("$CLAUDE" -p "Today is $TODAY. Health of the brain's own jobs: $HEALTH. If that is not \"all ok\", make it the first line of the brief, plainly. Then read prompts/brief.md and do exactly what it says." \
  --output-format text --allowedTools "$TOOLS" < /dev/null 2>&1)
RC=$?; echo "$OUT" >> "$LOG"
if [ $RC -ne 0 ]; then brain_check_limit "$OUT" || brain_fail "brief failed, exit $RC"; exit 1; fi
brain_ok
ONE=$(grep -m1 '^one:' data/brief.md 2>/dev/null | cut -c6- | cut -d'|' -f1)
brain_notify "brief $TODAY" "${ONE:-open data/brief.md}"
git add data/brief.md && { git diff --cached --quiet || git commit -q -m "brief: $TODAY"; } && brain_push
