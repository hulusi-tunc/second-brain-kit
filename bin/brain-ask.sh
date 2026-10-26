#!/bin/bash
# The brain in the notch: the Mac app (app/) calls this and reads lines back.
#   brain-ask.sh ask "question" ["earlier"]     STEP lines while it reads, then KIND/HEAD/NOTE/ROW (or NONE)
#                                               earlier: the conversation so far, for a follow-up
#   brain-ask.sh prep "title" "names" "HH:MM"   HEAD/OWE/ASK/PAGE lines for the card before a call
#   brain-ask.sh rewrite "instruction" < text   the rewritten text, or ASK, or NOT_AN_INSTRUCTION
# ask and prep read the repo, read only; rewrite has no tools. Works from a terminal too.
. "$(dirname "$(readlink -f "$0")")/brain-lib.sh" ask
cd "$SB" || exit 1
MODE="$1"; shift
TODAY=$(date "+%a %d %b %Y, %H:%M")
MODEL="${BRAIN_ASK_MODEL:-sonnet}"
# no project settings, MCP servers or session files: they cost seconds on every question
LEAN=(--strict-mcp-config --no-session-persistence --setting-sources "")
if brain_paused; then echo "KIND: error"; echo "HEAD: paused for a usage limit, brain resume clears it"; exit 0; fi

# the ledger rows that matter now: everything not done, plus what changed in the last 30 days, soonest due first
ledger() {
  python3 - <<'PY'
import re, datetime as dt
rows = []
cut = (dt.date.today() - dt.timedelta(days=30)).isoformat()
for l in open("commitments.md"):
    c = [x.strip() for x in l.split("|")]
    if len(c) < 9 or not re.match(r"\d{4}-\d{2}-\d{2}", c[2]): continue
    if not c[7].startswith("done") or c[2] >= cut:
        rows.append(c)
rows.sort(key=lambda c: (c[6] or "9999", c[2]))
print("ID | Opened | Owes | To | What | Due | Status | Source")
for c in rows: print(" | ".join(c[1:9]))
PY
}

case "$MODE" in
ask)
  Q="$1"; EARLIER="$2"
  CTX="$(ledger)"
  FOLLOW=""
  if [ -n "$EARLIER" ]; then
    FOLLOW="This is a follow-up. Earlier in the conversation (oldest first):
$EARLIER

Read the new question in that light: 'he', 'she', 'it', 'that', 'more', 'why' refer to what was asked and answered above. Do not repeat the earlier answer; answer what is new.

"
  fi
  echo "STEP: read || Reading the **ledger** || ledger:$(echo "$CTX" | tail -n +2 | grep -c .) rows"
  PROMPT="You answer the owner of this second brain from its files. Today is $TODAY. wiki/about-me.md says who they are, wiki/voice.md how they want to be written to. Below the question: their ledger (commitments.md, not-done rows plus the last 30 days, soonest due first). For people and projects read the wiki: wiki/index.md lists the pages, each person and project page starts with a ## Now block. archive/ holds the raw records. private/ is the personal layer; read it only if the question is personal. Be fast: answer from the ledger when it can, at most 3 tool calls otherwise. Before each search or read, write one short sentence, under 90 characters, of what you are looking for (it is shown while you work).

Pick the shape that fits the question, then reply only with these lines, nothing else:
KIND: fact | list | summary | none
HEAD: <fact: the answer itself in one line. list: what the list is, e.g. '4 open with Sam, 2 due this week'. summary: the state in one line. Under 70 characters>
NOTE: <summary only: 1 or 2 short sentences of context>
ROW: <one item, under 70 characters, no ids> || <when: 'Fri 2 Oct', 'since 30 Sep', or empty> || <state: overdue, due, open, done or info> || <source in words, under 30 characters> || <file path, e.g. commitments.md or wiki/sam.md>
(list: 1 to 5 ROW lines, most urgent first. fact: 0 to 2 ROW lines that back it up. summary: 0 to 4.)
For none: KIND: none, then NONE: <what you searched, for what, in plain words>.
Answer in the language of the question.

${FOLLOW}Question: $Q"
  OUT=$(mktemp)
  echo "$CTX" | "$CLAUDE" -p "$PROMPT" --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" "${LEAN[@]}" \
    --model "$MODEL" --output-format stream-json --verbose 2>/dev/null | python3 -u "$SB/bin/brain-steps.py" | tee "$OUT"
  grep -q "^KIND: error" "$OUT" && brain_check_limit "$(cat "$OUT")"
  rm -f "$OUT"
  ;;
prep)
  TITLE="$1"; NAMES="$2"; AT="$3"
  CTX="$(ledger)"
  PROMPT="The owner of this second brain has a call in a few minutes: \"$TITLE\" at $AT, with $NAMES. Today is $TODAY. Below: their ledger (not-done rows plus the last 30 days). Find the person's wiki page (wiki/index.md lists them; read its ## Now block) and the last meeting with them in archive/ (meeting-*.md, newest first) if there is one. At most 4 tool calls.

Reply only with these lines, nothing else:
HEAD: <last time you met, e.g. 'Last time, 18 Sep sync', or 'First call' if nothing> || <short count, e.g. '3 open' or 'Owed both ways'>
OWE: <an open item between you, short, with the due date> || <'You owe' or '<First name> owes'>   (0 to 4 lines, soonest due first)
ASK: <a question worth asking on this call, from what is open or unclear>   (1 or 2 lines)
PAGE: <the wiki page path, e.g. wiki/sam.md, or NONE>"
  echo "$CTX" | "$CLAUDE" -p "$PROMPT" --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" "${LEAN[@]}" \
    --model "$MODEL" --output-format text 2>&1 | grep -E "^(HEAD|OWE|ASK|PAGE):"
  ;;
rewrite)
  INSTR="$1"
  PROMPT="The owner selected the text below and said an instruction out loud: \"$INSTR\"

If the instruction is a question about their work or life rather than something to do to the text, reply exactly ASK.
If it is not an instruction at all (noise, a half sentence), reply exactly NOT_AN_INSTRUCTION.
Otherwise reply with only the rewritten text: no quotes, no preamble, no explanation. Change only what the instruction asks for: fixing grammar fixes grammar, every name and pronoun stays as written, no facts added, the tone kept. Keep the meaning, the facts and the language unless told to translate."
  # an empty folder: no project files for a rewrite to read
  T=$(mktemp -d); cd "$T" || exit 1
  "$CLAUDE" -p "$PROMPT" --tools "" "${LEAN[@]}" --model "$MODEL" --output-format text 2>&1
  rm -rf "$T"
  ;;
*)
  echo "usage: brain-ask.sh ask|prep|rewrite ..." >&2; exit 2 ;;
esac
