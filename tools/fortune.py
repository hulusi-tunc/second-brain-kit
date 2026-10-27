#!/usr/bin/env python3
"""Fortune teller: Slack ripples that will reach you, before they do. Used by bin/brain-fortune.sh.
  context [deep|quick]  -> what the scan links Slack against: open ledger, watchlist, your good and
                           noise verdicts, the fortunes already told (so none repeats)
  merge                 -> stdin is the model's JSON array; new ones get an id and land in
                           data/fortune.json (the live list) and data/fortune.jsonl (every one ever told);
                           prints the hot ones not yet notified, as JSON
  hotmsg | hotids       -> stdin is merge's output; a short line for the notification, or their ids
  pinged <id,...>       -> mark hot ones as notified
  feedback <v> <id>     -> good | noise | seen | open, from Brain Home or a terminal
  watch add|rm|ls [term]
The live list keeps 14 days; anything you called noise or seen leaves it."""
import json, os, re, sys, hashlib, datetime
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(R, "data")
LIVE = os.path.join(D, "fortune.json")
HIST = os.path.join(D, "fortune.jsonl")
FEED = os.path.join(D, "fortune-feedback.jsonl")
WATCH = os.path.join(D, "fortune-watch.txt")
KEEP_DAYS = 14
now = datetime.datetime.now().astimezone()


def load_live():
    try: return json.load(open(LIVE))
    except Exception: return {"generatedAt": "", "lastScan": "", "rows": []}


def save_live(d):
    cut = (now - datetime.timedelta(days=KEEP_DAYS)).isoformat()
    d["rows"] = [r for r in d["rows"] if r.get("at", "") >= cut]
    order = {"hot": 0, "soon": 1, "watch": 2}
    d["rows"].sort(key=lambda r: r.get("at", ""), reverse=True)
    d["rows"].sort(key=lambda r: (r.get("status") in ("noise", "seen"), order.get(r.get("urgency"), 3)))
    d["generatedAt"] = now.isoformat(timespec="seconds")
    json.dump(d, open(LIVE, "w"), ensure_ascii=False, indent=1)


def feedback_rows():
    out = []
    if os.path.exists(FEED):
        for l in open(FEED):
            try: out.append(json.loads(l))
            except Exception: pass
    return out


def watch_terms():
    if not os.path.exists(WATCH): return []
    return [l.strip() for l in open(WATCH) if l.strip() and not l.startswith("#")]


def open_ledger():
    rows = []
    for l in open(os.path.join(R, "commitments.md")):
        if not re.match(r"^\| c[0-9a-f]{7} \|", l): continue
        c = [x.strip() for x in l.strip().strip("|").split("|")]
        if len(c) < 7 or c[6] in ("done", "dropped"): continue
        rows.append(f"{c[0]} | {c[2]} owes {c[3]} | {c[4][:140]} | due {c[5] or '-'} | {c[6]}")
    return rows


def cmd_context(mode):
    live = load_live()
    out = [f"now: {now.isoformat(timespec='minutes')}", f"mode: {mode}",
           f"last scan: {live.get('lastScan') or 'never'}"]
    out.append("\n## watchlist (the owner's own words, always look for these)")
    out += [f"- {t}" for t in watch_terms()] or ["- (empty)"]
    out.append("\n## open ledger rows")
    out += open_ledger()
    fb = feedback_rows()[-60:]
    told = {r["id"]: r for r in live["rows"]}
    if os.path.exists(HIST):
        for l in open(HIST):
            try: r = json.loads(l); told.setdefault(r["id"], r)
            except Exception: pass
    if fb:
        out.append("\n## the owner's verdicts on past fortunes (learn from these: more like good, never like noise)")
        for f in fb:
            r = told.get(f.get("id"), {})
            if f.get("v") in ("good", "noise"):
                out.append(f"- {f['v']}: [{r.get('kind','')}] {r.get('text', f.get('id'))}" + (f" | note: {f['note']}" if f.get("note") else ""))
    out.append("\n## fortunes already told in the last 14 days (do not repeat; only a real new turn on one of these counts, then reuse its key)")
    for r in live["rows"]:
        out.append(f"- key {r.get('key')} | {r.get('status')} | {r.get('text')}")
    print("\n".join(out))


def fid(key):
    return "f" + hashlib.sha1(key.encode()).hexdigest()[:7]


def cmd_merge():
    txt = sys.stdin.read()
    m = re.search(r"\[.*\]", txt, re.S)
    if not m: sys.exit("no json array")
    items = json.loads(m.group(0))
    live = load_live()
    by_key = {r.get("key"): r for r in live["rows"]}
    new = 0
    hist = open(HIST, "a")
    for it in items:
        key = re.sub(r"[^a-z0-9-]", "", str(it.get("key", "")).lower().replace(" ", "-"))[:60]
        if not key or not it.get("text"): continue
        row = {"id": fid(key), "key": key, "at": now.isoformat(timespec="seconds"),
               "kind": it.get("kind", "ripple"), "urgency": it.get("urgency", "watch"),
               "about": it.get("about", ""), "text": it.get("text", "").strip(),
               "why": it.get("why", "").strip(), "seen": it.get("seen", "").strip(),
               "link": it.get("link", ""), "move": it.get("move", "").strip(),
               "draft": it.get("draft", "").strip(), "draftTo": it.get("draftTo", ""),
               "status": "new", "pinged": False}
        old = by_key.get(key)
        if old:
            # a new turn on a known story: same id, fresh text, back on top unless it was called noise
            if old.get("status") == "noise": continue
            row["pinged"] = old.get("pinged", False) and old.get("urgency") == row["urgency"]
            live["rows"].remove(old)
        live["rows"].append(row); by_key[key] = row; new += 1
        hist.write(json.dumps(row, ensure_ascii=False) + "\n")
    hist.close()
    live["lastScan"] = now.isoformat(timespec="seconds")
    save_live(live)
    hot = [r for r in live["rows"] if r["urgency"] == "hot" and r["status"] == "new" and not r.get("pinged")]
    print(json.dumps({"new": new, "hot": hot}, ensure_ascii=False))


def cmd_pinged(ids):
    live = load_live()
    for r in live["rows"]:
        if r["id"] in ids: r["pinged"] = True
    save_live(live)


def cmd_feedback(v, i, note="", via="cli"):
    if v not in ("good", "noise", "seen", "open") or not re.fullmatch(r"f[0-9a-f]{7}", i):
        sys.exit("usage: feedback good|noise|seen|open f1234567")
    live = load_live()
    hit = [r for r in live["rows"] if r["id"] == i]
    if not hit: print(f"no fortune {i}"); return False
    hit[0]["status"] = "new" if v == "open" else v
    save_live(live)
    with open(FEED, "a") as f:
        f.write(json.dumps({"v": v, "id": i, "at": now.isoformat(timespec="seconds"), "via": via, "note": note}, ensure_ascii=False) + "\n")
    print(f"{v} {i}: {hit[0]['text'][:80]}")
    return True


def cmd_watch(args):
    terms = watch_terms()
    op = args[0] if args else "ls"
    term = " ".join(args[1:]).strip()
    if op == "add" and term and term.lower() not in [t.lower() for t in terms]: terms.append(term)
    elif op == "rm": terms = [t for t in terms if t.lower() != term.lower()]
    if op in ("add", "rm"):
        open(WATCH, "w").write("# fortune watchlist: one term per line. brain watch <term> / brain unwatch <term>\n" + "".join(t + "\n" for t in terms))
    print("\n".join(terms) or "(empty)")


def cmd_hotmsg(ids_only=False):
    hot = json.load(sys.stdin)["hot"]
    if ids_only: print(",".join(r["id"] for r in hot)); return
    if not hot: return
    first = hot[0]
    more = f" (+{len(hot) - 1} more)" if len(hot) > 1 else ""
    print(f"{first['text']}{more}. Move: {first['move']}")


if __name__ == "__main__":
    a = sys.argv[1:] or ["context"]
    if a[0] == "context": cmd_context(a[1] if len(a) > 1 else "deep")
    elif a[0] == "merge": cmd_merge()
    elif a[0] == "pinged": cmd_pinged(set(",".join(a[1:]).split(",")))
    elif a[0] == "feedback": cmd_feedback(a[1], a[2], " ".join(a[3:]))
    elif a[0] == "watch": cmd_watch(a[1:])
    elif a[0] in ("hotmsg", "hotids"): cmd_hotmsg(a[0] == "hotids")
    else: sys.exit(__doc__)
