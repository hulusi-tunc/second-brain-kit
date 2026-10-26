# Shared by every scheduled job. Usage, first line of a job: . "$(dirname "$(readlink -f "$0")")/brain-lib.sh" <job>
# - Finds the repo from its own path and reads brain.config from the repo root.
# - A usage limit pauses every job until the reset time, instead of failing over and over.
# - Each job writes its health to ~/.second-brain/health/<job>: "<last ok epoch> <fails in a row> <reason>".
#   Three failures in a row send one notification. Summary: brain health
SB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
[ -f "$SB/brain.config" ] && { set -a; . "$SB/brain.config"; set +a; }
LOG="${BRAIN_LOG:-$HOME/Library/Logs/second-brain.log}"
BRANCH="${BRAIN_BRANCH:-main}"
CLAUDE="${CLAUDE_BIN:-claude}"
export PATH="$(dirname "$CLAUDE"):$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# optional: a separate Claude login for the jobs, so switching accounts in your terminal never stops them
[ -n "$BRAIN_CLAUDE_DIR" ] && export CLAUDE_CONFIG_DIR="$BRAIN_CLAUDE_DIR"
HEALTH_DIR="$HOME/.second-brain/health"
PAUSE_F="$HOME/.second-brain/pause"
JOB="${1:-job}"
mkdir -p "$HEALTH_DIR" "$(dirname "$LOG")"

brain_log() { echo "$(date '+%Y-%m-%d %H:%M') $*" >> "$LOG"; }
brain_notify() {
  if command -v osascript >/dev/null; then
    osascript -e "display notification \"$2\" with title \"second brain\" subtitle \"$1\"" 2>/dev/null
  elif command -v notify-send >/dev/null; then
    notify-send "second brain: $1" "$2"
  fi
}

brain_ok() { echo "$(date +%s) 0 ok" > "$HEALTH_DIR/$JOB"; }
brain_fail() {
  local prev last n
  prev=$(cat "$HEALTH_DIR/$JOB" 2>/dev/null)
  last=$(echo "$prev" | awk '{print $1+0}'); n=$(echo "$prev" | awk '{print $2+0}')
  n=$((n + 1))
  echo "$last $n $1" > "$HEALTH_DIR/$JOB"
  brain_log "$JOB: FAIL ($n in a row): $1"
  if [ "$n" -eq 3 ] || [ $((n % 30)) -eq 0 ]; then brain_notify "$JOB stopped" "$1"; fi
}

brain_paused() { [ -f "$PAUSE_F" ] && [ "$(date +%s)" -lt "$(cat "$PAUSE_F" 2>/dev/null || echo 0)" ]; }

# Did a failed run hit a usage limit or a logged-out account? Then pause every job until the reset.
brain_check_limit() {
  if echo "$1" | grep -qiE "Not logged in|run /login|invalid api key|token has expired"; then
    echo $(( $(date +%s) + 86400 )) > "$PAUSE_F"
    brain_notify "logged out" "the jobs' Claude login is gone, run: brain login"
    brain_log "$JOB: logged out, jobs paused for a day"
    return 0
  fi
  echo "$1" | grep -qiE "usage limit|hit your (weekly |session |daily )?limit|limit reached|rate.?limit" || return 1
  # reads "resets Oct 3 at 3pm" or "resets 5pm"; one hour if it cannot
  local until
  until=$(echo "$1" | python3 -c '
import re, sys, time, datetime as dt
t = sys.stdin.read()
m = re.search(r"resets\s+(?:([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)", t)
now = dt.datetime.now()
if not m:
    print(int(time.time()) + 3600); sys.exit()
mon, day, h, mi, ap = m.groups()
h = int(h) % 12 + (12 if ap == "pm" else 0); mi = int(mi or 0)
d = now.replace(hour=h, minute=mi, second=0, microsecond=0)
if mon: d = d.replace(month=dt.datetime.strptime(mon, "%b").month, day=int(day))
if d <= now: d += dt.timedelta(days=365 if mon else 1)
print(int(d.timestamp()) + 60)')
  brain_paused || brain_notify "paused" "usage limit, jobs wait until $(date -r "$until" '+%d %b %H:%M')"
  echo "$until" > "$PAUSE_F"
  brain_log "$JOB: usage limit, all jobs paused until $(date -r "$until" '+%d %b %H:%M')"
  return 0
}

brain_has_remote() { [ -n "$(git -C "$SB" remote)" ]; }
# local edits (an open note, Obsidian settings) never block a sync
brain_pull() {
  brain_has_remote || return 0
  git -C "$SB" pull -q --rebase --autostash origin "$BRANCH" 2>>"$LOG" && return 0
  git -C "$SB" rebase --abort 2>/dev/null
  brain_log "$JOB: git pull failed"; return 1
}
brain_push() {
  brain_has_remote || return 0
  git -C "$SB" push -q origin "$BRANCH" 2>>"$LOG" && return 0
  brain_pull && git -C "$SB" push -q origin "$BRANCH" 2>>"$LOG"
}

# one line: "all ok", or what is broken
brain_health_line() {
  local now out f job last n why
  now=$(date +%s); out=""
  for f in "$HEALTH_DIR"/*; do
    [ -f "$f" ] || continue
    job=$(basename "$f"); read -r last n why < "$f"
    if [ "${n:-0}" -ge 3 ]; then
      out="$out; $job failing $n times in a row ($why)"
    elif [ "${last:-0}" -gt 0 ] && [ $((now - last)) -gt 93600 ] && [ "$job" != sweep ]; then
      out="$out; $job has not run since $(date -r "$last" '+%d %b %H:%M')"
    fi
  done
  brain_paused && out="$out; paused for a usage limit until $(date -r "$(cat "$PAUSE_F")" '+%d %b %H:%M')"
  echo "${out#; }" | grep . || echo "all ok"
}
