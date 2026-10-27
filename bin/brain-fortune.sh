#!/bin/bash
# Fortune teller: reads every Slack workspace this brain is connected to (brain slack add) for things
# heading toward you (ripples, collisions, talk without you, drift, openings) and files them in
# data/fortune.json. Brain Home's Today list and the morning brief read that file; hot ones also show
# a notification right away.
#   bin/brain-fortune.sh [deep|quick]    deep: the last 7 days, drift included; quick: since the last scan
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" fortune
MODE="${1:-quick}"
cd "$SB" || exit 1
brain_paused && { brain_log "fortune: paused for a usage limit"; exit 0; }
TOOLS="ToolSearch,Read,Glob,Grep"
for n in $SLACK_WORKSPACES; do TOOLS="$TOOLS,mcp__slack-$n"; done
# the claude.ai Slack connector works too, listed in FORTUNE_TOOLS in brain.config
[ -n "$FORTUNE_TOOLS" ] && TOOLS="$TOOLS,$FORTUNE_TOOLS"
[ "$TOOLS" = "ToolSearch,Read,Glob,Grep" ] && { brain_log "fortune: no Slack connected, run brain slack add <name>"; exit 0; }
brain_pull
LOCK="$HOME/.second-brain/fortune.lock"
mkdir -p "$HOME/.second-brain"
if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +40 2>/dev/null)" ]; then exit 0; fi
rm -rf "$LOCK"; mkdir "$LOCK" || exit 0; trap 'rm -rf "$LOCK"' EXIT
mkdir -p data
NOW=$(date "+%Y-%m-%d %H:%M %Z")
brain_log "fortune: $MODE scan"
CTX=$(python3 tools/fortune.py context "$MODE")
OUT=$(perl -e 'alarm 1500; exec @ARGV' "$CLAUDE" -p "Now is $NOW. Read prompts/fortune.md and do exactly what it says.

$CTX" \
  --model "${BRAIN_ASK_MODEL:-sonnet}" --output-format text --allowedTools "$TOOLS" < /dev/null 2>&1)
RES=$(echo "$OUT" | python3 tools/fortune.py merge 2>>"$LOG")
if [ -z "$RES" ]; then
  brain_check_limit "$OUT" || brain_fail "fortune: no answer: $(echo "$OUT" | tr '\n' ' ' | head -c 160)"
  exit 1
fi
brain_ok
NEW=$(echo "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["new"])')
brain_log "fortune: $NEW new"
MSG=$(echo "$RES" | python3 tools/fortune.py hotmsg)
if [ -n "$MSG" ]; then
  brain_notify "Fortune, hot" "$MSG"
  python3 tools/fortune.py pinged "$(echo "$RES" | python3 tools/fortune.py hotids)" >/dev/null
fi
git add data/fortune.json data/fortune.jsonl && { git diff --cached --quiet || { git commit -q -m "fortune: $MODE, $NEW new" && brain_push; }; }
