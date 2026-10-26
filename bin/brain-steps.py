#!/usr/bin/env python3
"""Between Claude's stream and the notch: every file the brain opens or searches becomes a STEP
line, printed the moment it happens, so the notch shows what the brain is doing, each kind its own
look.

  STEP: kind || text with **the thing** in bold || chipkind:chip text;chipkind:chip text
  FOUND: 12 matches        (what the last search found, a chip on that step)

kinds: think (a sentence of what it is looking for), search, read, cal. chip kinds: person, meet,
proj, ledger, count. The answer's own lines (KIND, HEAD, NOTE, ROW, NONE) pass through at the end.
"""
import json, os, re, sys

SB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MON = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def title(slug):
    return " ".join(w.capitalize() if len(w) > 2 else w for w in slug.split("-"))


def page_kind(path):
    """person, proj or company from the page's tags; the title from its first heading"""
    p = path if os.path.isabs(path) else os.path.join(SB, path)
    kind, name = "proj", title(os.path.basename(p)[:-3])
    try:
        head = open(p, errors="replace").read(600)
        m = re.search(r"tags:\s*\[(\w+)", head)
        if m:
            kind = {"person": "person", "project": "proj", "company": "proj"}.get(m.group(1), "proj")
        h = re.search(r"^# (.+)$", head, re.M)
        if h:
            name = h.group(1).strip()
    except Exception:
        pass
    return kind, name


def where(path):
    p = path or ""
    if "commitments" in p: return "the ledger"
    if "wiki" in p: return "the wiki"
    if "archive" in p: return "past notes"
    if "private" in p: return "your private notes"
    if "raw" in p: return "today's notes"
    return "the brain"


def read(path):
    b = os.path.basename(path or "")
    if b == "commitments.md":
        return "read", "Reading the **ledger**", "ledger:Ledger"
    if b == "index.md":
        return "read", "Looking at the **wiki's index**", ""
    m = re.match(r"meeting-(\d{4})-(\d{2})-(\d{2})-?(.*)\.md$", b)
    if m:
        day = f"{int(m.group(3))} {MON[int(m.group(2)) - 1]}"
        what = title(m.group(4)) if m.group(4) else "meeting"
        return "read", f"Reading the **{day}** notes", f"meet:{what}, {day}"
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})-(.*)\.md$", b)
    if m:
        day = f"{int(m.group(3))} {MON[int(m.group(2)) - 1]}"
        return "read", f"Reading the **{day}** notes", f"meet:{title(m.group(4))}"
    if "/private/" in (path or "") or (path or "").startswith("private"):
        return "read", "Reading your **private notes**", ""
    if b.endswith(".md"):
        kind, name = page_kind(path)
        return "read", f"Reading **{name}**", f"{kind}:{name}"
    return "read", f"Reading **{b}**", ""


def step(name, inp):
    if name == "Read":
        return read(inp.get("file_path", ""))
    if name == "Grep":
        pat = (inp.get("pattern") or "").replace("\\b", "").replace("(?i)", "")
        pat = re.sub(r"[\\^$()\[\]{}?+*.]", "", pat).replace("|", ", ")[:40]
        return "search", (f"Searching {where(inp.get('path', ''))} for **{pat}**" if pat else f"Searching {where(inp.get('path', ''))}"), ""
    if name == "Glob":
        return "search", f"Looking through {where(inp.get('path', '') or inp.get('pattern', ''))}", ""
    return None


def out(line):
    print(line, flush=True)


pending = {}   # tool_use id -> kind, so a result can say what it found
for line in sys.stdin:
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("type") == "assistant":
        for c in (e.get("message") or {}).get("content", []):
            if c.get("type") == "text":
                # a sentence of what it is about to look for (the prompt asks for one before each step)
                t = c.get("text", "").strip()
                if t and not re.match(r"^(KIND|HEAD|ROW|NOTE|NONE):", t):
                    s = re.split(r"(?<=[.!?])\s", t.splitlines()[0])[0][:110]
                    if len(s) > 8:
                        out(f"STEP: think || {s}")
            if c.get("type") == "tool_use":
                s = step(c.get("name"), c.get("input") or {})
                if s:
                    kind, text, chip = s
                    pending[c.get("id")] = kind
                    out(f"STEP: {kind} || {text} || {chip}")
    elif e.get("type") == "user":
        for c in (e.get("message") or {}).get("content", []) or []:
            if isinstance(c, dict) and c.get("type") == "tool_result" and pending.get(c.get("tool_use_id")) == "search":
                body = c.get("content")
                if isinstance(body, list):
                    body = " ".join(x.get("text", "") for x in body if isinstance(x, dict))
                n = len([l for l in str(body or "").splitlines() if l.strip()])
                if n and "No matches" not in str(body):
                    out(f"FOUND: {n} match{'es' if n != 1 else ''}")
    elif e.get("type") == "result":
        text = e.get("result") or ""
        if e.get("is_error") or ("limit" in text.lower() and "KIND:" not in text):
            out("KIND: error"); out("HEAD: " + (text.strip().splitlines() or ["The brain did not answer"])[0][:120])
        for l in text.splitlines():
            if re.match(r"^(KIND|HEAD|ROW|NOTE|NONE):", l):
                out(l)
