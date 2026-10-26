#!/usr/bin/env python3
"""Collects one day of work for the nightly digest (brain-work.sh): your own prompts in Claude Code
sessions, per project, with the session titles, plus your git commits across PROJECTS_DIR.

Skipped on purpose: sessions inside the brain repo itself (they are already in the brain, and that is
where private/ is read), scratch and tmp folders, and sub-agent threads. Prompts are cut to 400
characters so the material stays small.
usage: brain-work-extract.py [YYYY-MM-DD]
"""
import datetime as dt, glob, json, os, re, subprocess, sys

H = os.path.expanduser("~")
SB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
PROJECTS = os.path.expanduser(os.environ.get("PROJECTS_DIR") or os.path.join(H, "Projects"))
day = sys.argv[1] if len(sys.argv) > 1 else dt.date.today().isoformat()
d0 = dt.datetime.fromisoformat(day).astimezone()
d1 = d0 + dt.timedelta(days=1)
SKIP = ("scratchpad", "-private-tmp-", "-tmp-")
author = subprocess.run(["git", "config", "--global", "user.email"], capture_output=True, text=True).stdout.strip()


def project_name(path):
    p = path.replace(PROJECTS + "/", "").replace(H + "/", "~/")
    return re.sub(r"-worktree-[a-z0-9-]+", "", p)


def in_brain(path):
    path = os.path.realpath(path)
    return path == SB or path.startswith(SB + "/")


sessions = {}
for f in glob.glob(os.path.join(H, ".claude", "projects", "*", "*.jsonl")):
    folder = os.path.basename(os.path.dirname(f))
    if any(s in folder for s in SKIP):
        continue
    if dt.datetime.fromtimestamp(os.path.getmtime(f)).astimezone() < d0:
        continue
    title, prompts, cwd = None, [], None
    for line in open(f, errors="replace"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "ai-title":
            title = d.get("aiTitle") or d.get("title") or title
        if d.get("type") != "user" or d.get("isSidechain"):
            continue
        ts = d.get("timestamp")
        if not ts:
            continue
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
        if not (d0 <= t < d1):
            continue
        c = (d.get("message") or {}).get("content")
        if not isinstance(c, str):
            continue
        c = c.strip()
        if not c or c.startswith("<") or c.startswith("[Request interrupted"):
            continue
        cwd = d.get("cwd") or cwd
        prompts.append(f"{t:%H:%M} {c[:400]}")
    if prompts and cwd and not in_brain(cwd):
        sessions.setdefault(project_name(cwd), []).append((title, prompts))

# git: every repo one or two levels under PROJECTS_DIR, your commits of the day on any branch
commits = {}
for g in glob.glob(os.path.join(PROJECTS, "*", ".git")) + glob.glob(os.path.join(PROJECTS, "*", "*", ".git")):
    repo = os.path.dirname(g)
    if "-worktree-" in repo or not os.path.isdir(g) or in_brain(repo):
        continue
    cmd = ["git", "-C", repo, "log", "--all", f"--since={d0.isoformat()}", f"--until={d1.isoformat()}",
           "--format=%ad %s", "--date=format:%H:%M"]
    if author:
        cmd.append(f"--author={author}")
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        continue
    if out:
        commits[project_name(repo)] = sorted(set(out.splitlines()))

print(f"# Material for {day}\n")
for proj, items in sorted(sessions.items()):
    print(f"## {proj} (Claude Code, {len(items)} session{'s' if len(items) > 1 else ''})")
    for title, prompts in items:
        if title:
            print(f"Session: {title}")
        for p in prompts[:25]:
            print("- " + p.replace("\n", " "))
    print()
for proj, lines in sorted(commits.items()):
    print(f"## {proj} (git, {len(lines)} commits)")
    for l in lines[:30]:
        print("- " + l)
    print()
