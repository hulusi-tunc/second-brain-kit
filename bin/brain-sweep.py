#!/usr/bin/env python3
"""Copies text documents dropped in INBOX_DIR (default ~/Inbox) into raw/ as text.
The originals stay where they are, no binaries enter git, and a file is never copied twice
(~/.second-brain/sweep.done). Word, Pages and RTF are converted with macOS textutil.
usage: brain-sweep.py
"""
import os, subprocess, glob

H = os.path.expanduser("~")
SB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
RAW = os.path.join(SB, "raw")
INBOX = os.path.expanduser(os.environ.get("INBOX_DIR") or os.path.join(H, "Inbox"))
DONE = os.path.join(H, ".second-brain", "sweep.done")
TEXT = {".md", ".txt"}
CONVERT = {".docx", ".doc", ".pages", ".rtf"}

done = set(open(DONE).read().splitlines()) if os.path.exists(DONE) else set()
new = []
for src in glob.glob(os.path.join(INBOX, "**", "*"), recursive=True):
    ext = os.path.splitext(src)[1].lower()
    if src in done or not os.path.isfile(src) or ext not in TEXT | CONVERT:
        continue
    stem = os.path.splitext(os.path.basename(src))[0]
    dst = os.path.join(RAW, f"inbox-{stem}{'.md' if ext == '.md' else '.txt'}")
    try:
        if ext in TEXT:
            open(dst, "w").write(open(src, errors="replace").read())
        else:
            subprocess.run(["textutil", "-convert", "txt", "-output", dst, src],
                           check=True, capture_output=True, timeout=60)
        open(dst, "a").write(f"\n\n<!-- source: {src} -->\n")
        done.add(src)
        new.append(os.path.basename(dst))
    except Exception as e:
        print(f"skipped {src}: {e}")
os.makedirs(os.path.dirname(DONE), exist_ok=True); open(DONE, "w").write("\n".join(sorted(done)))
print(f"{len(new)} new file(s) in raw/")
