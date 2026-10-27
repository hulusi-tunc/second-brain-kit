#!/usr/bin/env python3
"""Brain Home's data: reads the repo as it is and writes home/data.js for the page.
Wiki pages are the map's nodes and their links its edges; git says when each page was born and how
alive it is; the ledger and the meeting notes say what is owed and who was met. The owner is read
from wiki/about-me.md, and ledger rows owed by "Me" (or the owner's name) are theirs.
usage: python3 home/collect.py"""
import datetime as dt
import json
import os
import re
import subprocess
from collections import Counter, defaultdict

SB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data.js")
today = dt.date.today()
MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
LINK = re.compile(r"\]\(([a-z0-9-]+)\.md\)")


# the owner: "Me" in the ledger, or the name in wiki/about-me.md
ME_NAME = ""
try:
    _m = re.search(r"\*\*Name:\*\*\s*(.+)", open(os.path.join(SB, "wiki", "about-me.md")).read())
    ME_NAME = _m.group(1).strip() if _m and "{{" not in _m.group(1) else ""
except OSError:
    pass
ME = {"me", "i", "self", "myself", "you", ""} | ({ME_NAME.lower(), ME_NAME.split()[0].lower()} if ME_NAME else set())


def is_me(s):
    return (s or "").strip().strip("?").lower() in ME


def git(*args):
    return subprocess.run(["git", "-C", SB, *args], capture_output=True, text=True).stdout


def clean(s):
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    return re.sub(r"[*_`]", "", s).replace("—", "-").replace("–", "-").strip()


# nodes: the wiki pages that are things (people, projects, companies, topics)
nodes, links = {}, Counter()
for f in sorted(os.listdir(os.path.join(SB, "wiki"))):
    if not f.endswith(".md") or f == "index.md":
        continue
    slug = f[:-3]
    text = open(os.path.join(SB, "wiki", f), errors="replace").read()
    tag = (re.search(r"tags:\s*\[(\w+)", text) or [None, "topic"])[1]
    if tag == "hub":
        continue
    title = (re.search(r"^# (.+)$", text, re.M) or [None, slug])[1].strip()
    now = ""
    m = re.search(r"^## Now\s*\n+(.+?)(?=\n## |\Z)", text, re.M | re.S)
    if m:
        now = m.group(1).strip()
    # the Now block's prose only: its dashed lines (owed lists, last contact) are shown as lists already
    prose = " ".join(l.strip() for l in now.split("\n\n")[0].splitlines() if l.strip() and not l.strip().startswith("-")) if now else ""
    first = clean(prose) if prose else clean(now.split("\n\n")[0]) if now else clean(re.sub(r"^---.*?---", "", text, flags=re.S).split("\n# ")[-1].split("\n", 1)[-1].strip().split("\n\n")[0])
    # "Last contact: 2 Oct 16:49, ..." or "Last contact 1 Oct: ..." (both appear in the wiki)
    last = (re.search(r"Last contact:?\s*([^.:\n]+(?::\d{2})?[^.:\n]*)", now) or [None, ""])[1]
    nodes[slug] = {"id": slug, "title": title, "kind": "you" if slug == "about-me" else tag, "now": first[:600], "last": clean(last)}
    for target in set(LINK.findall(text)):
        if target != slug:
            links[tuple(sorted((slug, target)))] += 1

# git: when each page was born, how often it changed in the last 14 days, its last change
born, touched, lastday = {}, Counter(), {}
log = git("log", "--format=@%ad", "--date=short", "--name-only", "--", "wiki/")
day = None
for line in log.splitlines():
    if line.startswith("@"):
        day = line[1:]
        continue
    if line.startswith("wiki/") and line.endswith(".md"):
        slug = line[5:-3]
        born[slug] = day                      # the log runs newest first: the last seen is the birth
        lastday.setdefault(slug, day)
        if day and (today - dt.date.fromisoformat(day)).days <= 14:
            touched[slug] += 1
for s, n in nodes.items():
    n["born"] = born.get(s, today.isoformat())
    n["lastTouched"] = lastday.get(s, n["born"])
    n["heat"] = touched.get(s, 0)

# the ledger, per node: matched on a person's first name or a project's title in Owes, To or What
rows = []
for l in open(os.path.join(SB, "commitments.md"), errors="replace"):
    c = [x.strip() for x in l.split("|")]
    if len(c) < 9 or not re.match(r"c[0-9a-f]{7}$", c[1]):
        continue
    status = c[7].split()[0] if c[7] else ""
    if status not in ("open", "check", "slipped"):
        continue
    due = c[6][:10]
    state = "open"
    try:
        d = dt.date.fromisoformat(due)
        state = "overdue" if d < today else ("due" if (d - today).days <= 7 else "open")
    except ValueError:
        pass
    src = c[8]
    m = re.search(r"(meeting-\d{4}-\d{2}-\d{2}[a-z0-9-]*)", src)
    source = f"archive/{m.group(1)}.md" if m and os.path.exists(os.path.join(SB, "archive", m.group(1) + ".md")) else "commitments.md"
    rows.append({"id": c[1], "opened": c[2], "owes": c[3], "to": c[4], "what": clean(c[5]), "due": due, "state": state, "source": source,
                 "src": src, "kept": "kept " in src})


def keys(n):
    t = re.sub(r"\(.*?\)", "", n["title"]).strip()
    if n["kind"] == "person":
        return [t.split()[0]]
    # a project is also called by its first word ("Atlas" for Atlas by Northwind), when that word is a name
    return [t] + ([t.split()[0]] if len(t.split()[0]) > 3 and n["kind"] in ("project", "company") else [])


for n in nodes.values():
    if n["kind"] == "you":
        continue
    ks = [k.lower() for k in keys(n) if len(k) > 2]
    mine, theirs = [], []
    for r in rows:
        hay = f"{r['owes']} {r['to']} {r['what']}".lower()
        if not any(re.search(r"\b" + re.escape(k) + r"\b", hay) for k in ks):
            continue
        # only what is between you and them: someone's task for themselves is theirs, not yours
        if is_me(r["owes"]):
            mine.append(r)
        elif is_me(r["to"]):
            theirs.append(r)
    order = {"overdue": 0, "due": 1, "open": 2}
    n["mine"] = sorted(mine, key=lambda r: order[r["state"]])[:8]
    n["_all"] = [r["id"] for r in mine]
    n["theirs"] = sorted(theirs, key=lambda r: order[r["state"]])[:8]
    n["dues"] = sorted(r["due"] for r in mine if r["due"])   # rewind: what was overdue on a given day
    n["overdue"] = sum(1 for r in mine if r["state"] == "overdue")
    n["open"] = len(mine) + len(theirs)

# meetings: the archived notes, with the nodes each one names
meetings = []
for f in sorted(os.listdir(os.path.join(SB, "archive")), reverse=True):
    if not f.startswith("meeting-") or not f.endswith(".md"):
        continue
    text = open(os.path.join(SB, "archive", f), errors="replace").read()
    title = (re.search(r"^# (.+)$", text, re.M) or [None, f])[1].strip()
    when = (re.search(r"^date:\s*(\d{4}-\d{2}-\d{2})(?:\s+(\d{1,2}:\d{2}))?(?:,\s*(\d+)\s*min)?", text, re.M))
    date = when.group(1) if when else f[8:18]
    start = when.group(2) if when and when.group(2) else ""
    mins = int(when.group(3)) if when and when.group(3) else 30
    summary = text.split("## Transcript")[0]
    hits = [n["id"] for n in nodes.values() if n["kind"] != "you" and any(re.search(r"\b" + re.escape(k.lower()) + r"\b", summary.lower()) for k in keys(n) if len(k) > 2)]
    meetings.append({"title": title, "date": date, "start": start, "mins": mins, "nodes": hits[:12], "file": f"archive/{f}"})
MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
for n in nodes.values():
    met = [m for m in meetings if n["id"] in m["nodes"]]
    n["meetings"] = [{"title": m["title"], "date": m["date"], "start": m["start"], "file": m["file"]} for m in met[:5]]
    n["metDates"] = sorted({m["date"] for m in met})
    # the last time you spoke with them: a call naming them, or the wiki's "Last contact 2 Oct"
    last = max(n["metDates"]) if n["metDates"] else ""
    lm = re.match(r"(\d{1,2})\s+([A-Za-z]{3})", n.get("last", ""))
    if lm and lm.group(2).lower() in MONTHS:
        d = dt.date(today.year, MONTHS.index(lm.group(2).lower()) + 1, int(lm.group(1)))
        if d > today: d = d.replace(year=today.year - 1)
        last = max(last, d.isoformat())
    n["contact"] = last
    n["text"] = " ".join([n["now"]] + [r["what"] for r in n.get("mine", []) + n.get("theirs", [])])[:1500]

edges = [{"a": a, "b": b, "w": w} for (a, b), w in links.items() if a in nodes and b in nodes]
mine_all = [r for r in rows if is_me(r["owes"])]
theirs_all = [r for r in rows if is_me(r["to"]) and not is_me(r["owes"])]
changed = sorted({os.path.basename(x)[:-3] for x in git("log", f"--since={(today - dt.timedelta(days=1)).isoformat()}", "--name-only", "--format=", "--", "wiki/").split() if x.endswith(".md")})

def local_hour(ts):
    try:
        v = dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00").replace(" +00:00", "+00:00"))
        v = v.astimezone() if v.tzinfo else v
        return v.date(), v.hour
    except Exception:
        return None, None


day = {"dictations": [0] * 24, "asks": [0] * 24, "calls": []}
path = os.path.join(SB, "private", "voice", "history.jsonl")
if os.path.exists(path):
    for l in open(path):
        try:
            d, h = local_hour(json.loads(l).get("at"))
            if d == today: day["dictations"][h] += 1
        except Exception:
            pass
hist = os.path.join(SB, "private", "brain", "history.jsonl")
if os.path.exists(hist):
    for l in open(hist):
        try:
            d, h = local_hour(json.loads(l).get("at"))
            if d == today: day["asks"][h] += 1
        except Exception:
            pass
day["calls"] = [{"title": m["title"], "start": m["start"], "mins": m["mins"], "nodes": m["nodes"], "file": m["file"]} for m in meetings if m["date"] == today.isoformat() and m["start"]]

day["agenda"] = None
# the review: what Brain filed since yesterday and you have not checked yet. Ledger rows grouped by
# where they were heard (a call, a channel); wiki pages with the lines added to them.
since = (today - dt.timedelta(days=1)).isoformat()
groups = {}
for r in rows:
    if r["opened"] < since or r["kept"]:
        continue
    m = re.search(r"(meeting-\d{4}-\d{2}-\d{2}[a-z0-9-]*)", r["src"])
    ch = re.search(r"\[(#[^\]]+?)(?:\s+\d{1,2}\s+\w{3}.*?)?\]\((https?://[^)]+)\)", r["src"]) or re.search(r"(#[a-z0-9_-]+)", r["src"])
    if m:
        key = m.group(1)
        f = os.path.join(SB, "archive", key + ".md")
        title = (re.search(r"^# (.+)$", open(f, errors="replace").read(800), re.M) or [None, key])[1].strip() if os.path.exists(f) else key
        g = groups.setdefault(key, {"key": key, "title": clean(title), "file": f"archive/{key}.md" if os.path.exists(f) else "", "url": "", "rows": []})
    elif ch:
        key = ch.group(1)
        g = groups.setdefault(key, {"key": key, "title": key, "file": "", "url": ch.group(2) if ch.lastindex and ch.lastindex > 1 else "", "rows": []})
    elif re.search(r"projects/([a-z0-9-]+)/", r["src"]):
        slug = re.search(r"projects/([a-z0-9-]+)/", r["src"]).group(1)
        node = next((n for n in nodes.values() if n["id"].startswith(slug.split("-")[0])), None)
        f = re.search(r"(projects/[^\s;,]+\.md)", r["src"])
        g = groups.setdefault(slug, {"key": slug, "title": (node["title"] if node else slug) + " files", "file": f.group(1) if f else "", "url": "", "rows": []})
    elif re.match(r"(\d{4}-\d{2}-\d{2})-(\w+)", r["src"]):
        d, kind = re.match(r"(\d{4}-\d{2}-\d{2})-(\w+)", r["src"]).groups()
        f = next((x for x in (f"archive/{d}-{kind}.md", f"raw/{d}-{kind}.md") if os.path.exists(os.path.join(SB, x))), "")
        g = groups.setdefault(d + kind, {"key": d + kind, "title": f"{kind.capitalize()} notes, {int(d[8:])} {MONTHS[int(d[5:7]) - 1].capitalize()}", "file": f, "url": "", "rows": []})
    else:
        g = groups.setdefault("other", {"key": "other", "title": "From your notes", "file": "", "url": "", "rows": []})
    g["rows"].append({k: r[k] for k in ("id", "opened", "owes", "to", "what", "due", "state")})
review_rows = sorted(groups.values(), key=lambda g: (max(x["opened"] for x in g["rows"]), len(g["rows"])), reverse=True)
pages = defaultdict(list)
cur = None
for line in git("log", f"--since={since}", "-p", "--format=tformat:@@", "--no-color", "-U0", "--", "wiki/").splitlines():
    if line.startswith("+++ b/wiki/") and line.endswith(".md"):
        cur = line[11:-3]
        continue
    if line.startswith("+++") or line.startswith("---") or not cur or not line.startswith("+"):
        continue
    t = line[1:].strip()
    if not t or t.startswith(("tags:", "updated:", "---", "#", "|")) or len(t) < 24:
        continue
    t = clean(re.sub(r"^[-*]\s+", "", t))
    if t not in pages[cur]:
        pages[cur].append(t[:220])
wrote = [{"id": k, "title": nodes[k]["title"] if k in nodes else k.replace("-", " ").capitalize(), "lines": v[:3], "more": max(0, len(v) - 3)}
         for k, v in sorted(pages.items(), key=lambda kv: -len(kv[1])) if v]

data = {
    "root": SB,
    "me": ME_NAME,
    "day": day,
    "today": today.isoformat(),
    "nodes": list(nodes.values()), "edges": edges,
    "meetings": meetings[:120],
    "counts": {"overdue": sum(1 for r in mine_all if r["state"] == "overdue"), "due": sum(1 for r in mine_all if r["state"] == "due"),
               "theirs": sum(1 for r in theirs_all if r["state"] == "overdue"), "changed": len(changed)},
    "changed": changed,
    "review": {"since": since, "groups": review_rows, "wrote": wrote},
}
# real photos when there are any (home/photos/<page>.jpg or .png, kept out of git)
HERE = os.path.dirname(os.path.abspath(__file__))
for n in data["nodes"]:
    for ext in ("jpg", "jpeg", "png", "webp"):
        if os.path.exists(os.path.join(HERE, "photos", f"{n['id']}.{ext}")):
            n["photo"] = f"photos/{n['id']}.{ext}"
            break
# the sweep: every overdue thing you owe, oldest first, with who it is about
by_row = defaultdict(list)
for n in data["nodes"]:
    for rid in n.pop("_all", []):
        by_row[rid].append(n["id"])
# the week: what closed, what slipped, what came in, what is due in the next 7 days.
# Closed is read from git: rows that were not done or dropped 7 days ago and are now.
def ledger_rows(text):
    out = {}
    for l in text.splitlines():
        c = [x.strip() for x in l.split("|")]
        if len(c) >= 9 and re.match(r"c[0-9a-f]{7}$", c[1]):
            out[c[1]] = {"id": c[1], "opened": c[2], "owes": c[3], "to": c[4], "what": clean(c[5]), "due": c[6][:10],
                         "status": (c[7].split() or [""])[0]}
    return out
wk0 = (today - dt.timedelta(days=7)).isoformat()
then_rev = git("rev-list", "-1", f"--before={wk0} 23:59", "HEAD").strip()
before = ledger_rows(git("show", f"{then_rev}:commitments.md")) if then_rev else {}
now_rows = ledger_rows(open(os.path.join(SB, "commitments.md"), errors="replace").read())
wk_ok = lambda r: True
closed = [r for r in now_rows.values() if r["status"] in ("done", "dropped") and before.get(r["id"], {}).get("status") not in ("done", "dropped") and wk_ok(r)]
slipped = [r for r in now_rows.values() if r["status"] in ("open", "check", "slipped") and wk0 <= r["due"] < today.isoformat() and wk_ok(r)]
fresh = [r for r in now_rows.values() if r["opened"] > wk0 and wk_ok(r)]
ahead = sorted([r for r in now_rows.values() if r["status"] in ("open", "check", "slipped") and today.isoformat() <= r["due"] <= (today + dt.timedelta(days=7)).isoformat() and wk_ok(r)],
               key=lambda r: (not is_me(r["owes"]), r["due"]))
data["week"] = {"from": wk0, "closed": sorted(closed, key=lambda r: (not is_me(r["owes"]), r["what"])), "slipped": slipped,
                "fresh": len(fresh), "freshMine": sum(1 for r in fresh if is_me(r["owes"])), "ahead": ahead,
                "meetings": len({(m["date"], m["start"]) for m in meetings if m["date"] > wk0})}
# rows another tool found evidence for (data/looks-done.json, optional) come first, with the line
# that shows it; you confirm each, nothing closes by itself
try:
    looks = json.load(open(os.path.join(SB, "data", "looks-done.json")))["rows"]
except Exception:
    looks = {}
data["sweep"] = [{**{k: r[k] for k in ("id", "opened", "owes", "to", "what", "due", "source")}, "nodes": by_row.get(r["id"], []),
                  **({"seen": looks[r["id"]]["seen"], "seenLink": looks[r["id"]]["link"]} if r["id"] in looks else {})}
                 for r in sorted(rows, key=lambda r: (r["id"] not in looks, r["due"] or "9"))
                 if (r["id"] in looks or (is_me(r["owes"]) and r["state"] == "overdue"))]
# fortunes: what Slack shows heading your way, from bin/brain-fortune.sh (data/fortune.json). Only
# the ones not answered yet; good, noise and seen leave the list
try:
    fr = json.load(open(os.path.join(SB, "data", "fortune.json")))
except Exception:
    fr = {"rows": [], "lastScan": ""}
data["fortune"] = {"lastScan": fr.get("lastScan", ""), "rows": [
    {k: r.get(k, "") for k in ("id", "at", "kind", "urgency", "about", "text", "why", "seen", "link", "move", "draft", "draftTo")}
    for r in fr.get("rows", []) if r.get("status") == "new"]}
open(OUT, "w").write("window.BRAIN = " + json.dumps(data, ensure_ascii=False) + ";\n")
kinds = Counter(n["kind"] for n in nodes.values())
print(f"review: {sum(len(g['rows']) for g in review_rows)} rows in {len(review_rows)} groups, {len(wrote)} pages written")
print(f"{len(nodes)} nodes {dict(kinds)}, {len(edges)} links, {len(meetings)} meetings, "
      f"born {min(n['born'] for n in nodes.values())} to {max(n['born'] for n in nodes.values())}, "
      f"{sum(1 for n in nodes.values() if n['heat'])} touched in 14 days, {sum(1 for n in nodes.values() if n.get('overdue'))} with something overdue")
