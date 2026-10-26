#!/bin/bash
# After a call the Mac app recorded: adds a title, a summary and next steps to the meeting note in
# raw/, and renames the file after the title. The nightly /translate then files it like any meeting.
# usage: brain-call-notes.sh raw/meeting-....md
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" call-notes
NOTE="$1"
[ -f "$NOTE" ] || { brain_log "call-notes: no file $NOTE"; exit 1; }
cd "$SB" || exit 1
brain_paused && { brain_log "call-notes: paused for a usage limit, $(basename "$NOTE") stays without a summary"; exit 0; }
PROMPT='Below is the transcript of a call, recorded on the owner'"'"'s Mac: the first name in participants is their own mic, the other is the call. Write in the language most of the call was in:
TITLE: <the call in 2 to 5 words, e.g. "Pricing with Sam">
## Summary
<3 to 6 sentences: what was decided, what is open, numbers and dates as said>
## Next steps
- <Owner>: <action>, <due if said>
Only what is in the transcript. Speaker labels can be wrong: decide who owes from what is said. No filler, no greeting.'
OUT=$("$CLAUDE" -p "$PROMPT" --tools "" --output-format text < "$NOTE" 2>&1)
RC=$?
if [ $RC -ne 0 ] || ! echo "$OUT" | grep -q "^## Summary"; then
  brain_check_limit "$OUT" || brain_fail "summary failed for $(basename "$NOTE")"
  exit 1
fi
brain_ok
NEW=$(python3 - "$NOTE" "$OUT" <<'PY'
import os, re, sys
path, out = sys.argv[1], sys.argv[2]
title = re.search(r"^TITLE:\s*(.+)$", out, re.M)
body = out[out.index("## Summary"):].strip()
s = open(path, encoding="utf-8").read()
if title:
    s = re.sub(r"^# .*$", "# " + title.group(1).strip().strip('"'), s, count=1, flags=re.M)
s = s.replace("## Transcript", body + "\n\n## Transcript", 1)
open(path, "w", encoding="utf-8").write(s)
if title:
    slug = re.sub(r"[^a-z0-9]+", "-", title.group(1).lower()).strip("-")[:40]
    day = re.search(r"meeting-(\d{4}-\d{2}-\d{2})", os.path.basename(path))
    if day and slug:
        new = os.path.join(os.path.dirname(path), f"meeting-{day.group(1)}-{slug}.md")
        if not os.path.exists(new):
            os.rename(path, new); path = new
print(path)
PY
)
brain_log "call-notes: summary added to $(basename "$NEW")"
brain_notify "Call notes ready" "$(head -1 "$NEW" | sed 's/^# //')"
