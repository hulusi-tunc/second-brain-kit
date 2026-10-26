#!/usr/bin/env python3
"""Optional: drops finished Wispr Flow meetings into raw/, one file each (summary, notes, transcript).

- Reads a copy of Wispr Flow's local database (with -wal and -shm), so the running app is never locked.
- Takes finalized, non-deleted meetings. Ones already written are remembered in ~/.second-brain/wispr.done.
- Each meeting: raw/meeting-YYYY-MM-DD-<slug>.md
usage: wispr-sync.py [--dry-run]
"""
import os, sys, json, shutil, sqlite3, tempfile, re, datetime as dt

H = os.path.expanduser("~")
W = os.path.join(H, "Library", "Application Support", "Wispr Flow")
SB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
RAW = os.path.join(SB, "raw")
DONE = os.path.join(H, ".second-brain", "wispr.done")
DRY = "--dry-run" in sys.argv


def slug(s, n=40):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower().encode("ascii", "ignore").decode()).strip("-")
    return s[:n] or "meeting"


def local(ts):
    if not ts:
        return None
    t = dt.datetime.fromisoformat(str(ts).replace(" +00:00", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.astimezone()


def speakers(speaker_map):
    names = {}
    try:
        sm = json.loads(speaker_map or "{}")
        people, assign = sm.get("people", {}), sm.get("assignments", {})
        for sid, pid in assign.items():
            if pid in people and people[pid].get("name"):
                names[str(sid)] = people[pid]["name"]
    except Exception:
        pass
    return names


def transcript(mid, names):
    d = os.path.join(W, "meetings", mid)
    f = next((os.path.join(d, n) for n in ("refined.ndjson", "live.ndjson") if os.path.exists(os.path.join(d, n))), None)
    if not f:
        return ""
    out = []
    for line in open(f, errors="replace"):
        try:
            j = json.loads(line)
        except Exception:
            continue
        sid = str((j.get("speaker") or {}).get("id", "?"))
        who = names.get(sid) or (j.get("speaker") or {}).get("name") or f"Speaker {sid}"
        txt = (j.get("text") or "").strip()
        if txt:
            out.append(f"[{j.get('timestamp', '')}] {who}: {txt}")
    return "\n".join(out)


def main():
    live = os.path.join(W, "flow.sqlite")
    if not os.path.exists(live):
        print("Wispr Flow not found, nothing to do")
        return
    done = set(open(DONE).read().split()) if os.path.exists(DONE) else set()
    q = """select id, title, createdAt, endedAt, participantNames, summary, notes, speakerMap
           from Meetings where finalized=1 and isDeleted=0 and coalesce(isTourDemo,0)=0 order by createdAt"""
    try:
        with tempfile.TemporaryDirectory() as td:
            for suf in ("", "-wal", "-shm"):
                if os.path.exists(live + suf):
                    shutil.copy2(live + suf, os.path.join(td, "flow.sqlite" + suf))
            con = sqlite3.connect(os.path.join(td, "flow.sqlite"))
            rows = con.execute(q).fetchall()
            con.close()
    except OSError:
        # not enough disk to stage a copy: read the live file read-only
        con = sqlite3.connect(f"file:{live}?mode=ro", uri=True)
        rows = con.execute(q).fetchall()
        con.close()
    new = []
    for mid, title, created, ended, parts, summary, notes, smap in rows:
        if mid in done:
            continue
        t0 = local(created)
        title = (title or "Untitled meeting").strip()
        try:
            plist = json.loads(parts) if parts else []
        except Exception:
            plist = []
        dur = ""
        if ended and t0:
            try:
                e = dt.datetime.fromtimestamp(int(ended) / 1000, tz=dt.timezone.utc)
                dur = f"{int((e - t0).total_seconds() // 60)} min"
            except Exception:
                pass
        body = [f"# {title}", "",
                f"date: {t0.strftime('%Y-%m-%d %H:%M') if t0 else '?'}" + (f", {dur}" if dur else ""),
                f"participants: {', '.join(plist) if plist else 'not recorded'}",
                "source: Wispr Flow", ""]
        if summary and summary.strip():
            body += ["## Summary", "", summary.strip(), ""]
        if notes and notes.strip():
            body += ["## Notes", "", notes.strip(), ""]
        tr = transcript(mid, speakers(smap))
        if tr:
            body += ["## Transcript", "", tr, ""]
        if not (summary or notes or tr):
            continue
        name = f"meeting-{t0.strftime('%Y-%m-%d') if t0 else 'undated'}-{slug(title)}.md"
        path, i = os.path.join(RAW, name), 2
        while os.path.exists(path):
            path = os.path.join(RAW, name[:-3] + f"-{i}.md")
            i += 1
        if DRY:
            print(f"  -> {os.path.basename(path)}")
            continue
        open(path, "w").write("\n".join(body))
        done.add(mid)
        new.append(os.path.basename(path))
    if not DRY:
        os.makedirs(os.path.dirname(DONE), exist_ok=True)
        open(DONE, "w").write("\n".join(sorted(done)))
    print(f"{len(new)} meeting(s) into raw/")


if __name__ == "__main__":
    main()
