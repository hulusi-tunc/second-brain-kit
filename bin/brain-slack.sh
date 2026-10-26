#!/bin/bash
# Several Slack workspaces in one brain: one read-only MCP server per workspace.
#   brain slack add <name>      paste that workspace's token, check it, add the slack-<name> server
#   brain slack ls              the workspaces this brain reads
#   brain slack remove <name>   take one out (the token is deleted from the Keychain)
# How to get a token for a workspace: README, "Slack, every workspace".
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" slack
CONF="$SB/brain.config"
[ -f "$CONF" ] || cp "$SB/brain.config.example" "$CONF"

set_workspaces() {  # rewrite SLACK_WORKSPACES in brain.config
  python3 - "$CONF" "$1" <<'PY'
import re, sys
path, value = sys.argv[1:]
s = open(path).read()
line = f'SLACK_WORKSPACES="{value}"'
s = re.sub(r'^SLACK_WORKSPACES=.*$', line, s, flags=re.M) if re.search(r'^SLACK_WORKSPACES=', s, re.M) else s.rstrip("\n") + "\n\n" + line + "\n"
open(path, "w").write(s)
PY
}
store_token() {
  if command -v security >/dev/null; then
    security add-generic-password -U -s second-brain-slack -a "$1" -w "$2"
  else
    mkdir -p "$HOME/.second-brain/slack"; umask 077; printf '%s' "$2" > "$HOME/.second-brain/slack/$1.token"
  fi
}
drop_token() {
  if command -v security >/dev/null; then security delete-generic-password -s second-brain-slack -a "$1" >/dev/null 2>&1
  else rm -f "$HOME/.second-brain/slack/$1.token"; fi
}

case "$1" in
  add)
    NAME="$2"
    [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "usage: brain slack add <name>, lowercase, like: agency or northwind"; exit 1; }
    command -v npx >/dev/null || { echo "needs Node.js (npx) for the Slack server: https://nodejs.org"; exit 1; }
    read -r -s -p "User OAuth Token for '$NAME' (starts with xoxp-): " TOKEN; echo
    [[ "$TOKEN" == xoxp-* ]] || { echo "that is not a user token (xoxp-...). See README, Slack."; exit 1; }
    AUTH=$(curl -s -H "Authorization: Bearer $TOKEN" https://slack.com/api/auth.test)
    echo "$AUTH" | grep -q '"ok":true' || { echo "Slack refused the token: $(echo "$AUTH" | sed 's/.*"error":"\([^"]*\)".*/\1/')"; exit 1; }
    TEAM=$(echo "$AUTH" | sed 's/.*"team":"\([^"]*\)".*/\1/'); WHO=$(echo "$AUTH" | sed 's/.*"user":"\([^"]*\)".*/\1/')
    store_token "$NAME" "$TOKEN"
    cd "$SB" && "$CLAUDE" mcp remove --scope local "slack-$NAME" >/dev/null 2>&1
    "$CLAUDE" mcp add --scope local "slack-$NAME" -- "$SB/bin/slack-mcp" "$NAME" >/dev/null || { echo "claude mcp add failed"; exit 1; }
    set_workspaces "$(echo $SLACK_WORKSPACES "$NAME" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"
    echo "added slack-$NAME: $TEAM, as $WHO. Read-only. Claude in this folder can now search it." ;;
  remove)
    NAME="$2"; [ -z "$NAME" ] && { echo "usage: brain slack remove <name>"; exit 1; }
    drop_token "$NAME"
    cd "$SB" && "$CLAUDE" mcp remove --scope local "slack-$NAME" >/dev/null 2>&1
    set_workspaces "$(echo $SLACK_WORKSPACES | tr ' ' '\n' | grep -vx "$NAME" | tr '\n' ' ' | sed 's/ $//')"
    echo "removed slack-$NAME" ;;
  ls|"")
    [ -z "$SLACK_WORKSPACES" ] && { echo "no Slack workspaces yet. Add one: brain slack add <name>"; exit 0; }
    for n in $SLACK_WORKSPACES; do
      if command -v security >/dev/null; then T=$(security find-generic-password -s second-brain-slack -a "$n" -w 2>/dev/null)
      else T=$(cat "$HOME/.second-brain/slack/$n.token" 2>/dev/null); fi
      R=$(curl -s -H "Authorization: Bearer $T" https://slack.com/api/auth.test)
      if echo "$R" | grep -q '"ok":true'; then echo "slack-$n: ok, $(echo "$R" | sed 's/.*"team":"\([^"]*\)".*/\1/')"
      else echo "slack-$n: broken ($(echo "$R" | sed 's/.*"error":"\([^"]*\)".*/\1/')), run: brain slack add $n"; fi
    done ;;
  *) sed -n '2,6p' "$0" ;;
esac
