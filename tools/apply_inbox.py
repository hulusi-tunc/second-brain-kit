#!/usr/bin/env python3
"""data/inbox.jsonl (written by Brain Home: done, keep, drop, still on) -> commitments.md. Then empties the file."""
import json, os, re, sys, subprocess, datetime
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(R, "data", "inbox.jsonl")
if not os.path.exists(P): raise SystemExit("no inbox")
lines = [l for l in open(P).read().splitlines() if l.strip()]
if not lines: raise SystemExit("inbox empty")
today = datetime.date.today().isoformat()
cm = open(os.path.join(R, "commitments.md")).read()
raw_path = os.path.join(R, "raw", f"{today}.md")
done = reopened = thoughts = kept = dropped = moved = fortunes = 0
for l in lines:
    try: e = json.loads(l)
    except Exception: continue
    t = e.get("t"); ts = (e.get("at") or "")[11:16] or datetime.datetime.now().strftime("%H:%M")
    if t in ("done", "reopen", "keep", "drop", "due") and re.fullmatch(r"c[0-9a-f]{7}", e.get("id", "")):
        m = re.search(rf"^\| {e['id']} \|.*$", cm, re.M)
        if not m: continue
        c = [x.strip() for x in m.group(0).strip().strip("|").split("|")]
        via = e.get('via') or 'Brain Home'
        if t == "done":
            c[6] = "done"; c[7] = c[7] + f", done {today} via {via}"; done += 1
        # Brain Home's review: a row Brain filed, checked by you. Kept stays as it is, marked so the
        # queue lets it go; dropped was never a promise, it leaves the open list
        elif t == "keep":
            if "kept " not in c[7]: c[7] = c[7] + f", kept {today}"
            kept += 1
        # Brain Home's sweep, "still on": the promise stands, with a new date
        elif t == "due" and re.fullmatch(r"\d{4}-\d{2}-\d{2}", e.get("date", "")):
            c[5] = e["date"]; c[6] = "open"; c[7] = c[7] + f", moved to {e['date']} on {today} via {via}"; moved += 1
        elif t == "drop":
            c[6] = "dropped"; c[7] = c[7] + f", dropped {today} via {via}"; dropped += 1
        else:
            c[6] = "open"; reopened += 1
        cm = cm.replace(m.group(0), "| " + " | ".join(c) + " |")
    # fortune verdicts from Brain Home: good, noise, seen, open on an f-id
    elif t in ("good", "noise", "seen", "open") and re.fullmatch(r"f[0-9a-f]{7}", e.get("id", "")):
        r = subprocess.run([sys.executable, os.path.join(R, "tools", "fortune.py"), "feedback", t, e["id"], e.get("note", "")],
                           capture_output=True, text=True)
        if r.returncode == 0: fortunes += 1
    elif t == "watch" and e.get("text", "").strip():
        subprocess.run([sys.executable, os.path.join(R, "tools", "fortune.py"), "watch", e.get("op", "add"), e["text"].strip()], capture_output=True)
        fortunes += 1
    elif t in ("brain", "answer"):
        text = e.get("text", "").strip()
        if t == "answer": text = f"answer to the brief question: {e.get('q','').strip()}\n{text}"
        if not text: continue
        new = not os.path.exists(raw_path)
        with open(raw_path, "a") as f:
            if new: f.write(f"# {today}\n\n")
            f.write(f"## {ts}\n\n{text}\n\n")
        thoughts += 1
open(os.path.join(R, "commitments.md"), "w").write(cm)
open(P, "w").write("")
print(f"inbox: {done} done, {reopened} reopened, {kept} kept, {dropped} dropped, {moved} moved, {thoughts} thoughts, {fortunes} fortune")
