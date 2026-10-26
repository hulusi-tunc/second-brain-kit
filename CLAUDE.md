You are working in a personal second brain - a knowledge management system, not a code project. Your job is to keep the wiki current, useful and well organized based on the raw notes the owner captures.

Read `README.md` for how the system works. Read `wiki/about-me.md` for who the owner is and `wiki/voice.md` for how they want things written. Both are filled in by `setup.sh` and the `/interview` command.

---

## Hard rules

1. **Never delete** anything from `raw/` or `archive/`. Move only, never delete.
2. **Never overwrite** a `wiki/` entry blindly. Read it first, then merge.
3. **Never modify** `archive/` after a file lands there. It is the permanent record.
4. **Commit after meaningful changes** with a clear message, for example `translate: 4 raw files processed`. Stage the paths you touched, never `git add -A`.
5. **When uncertain, write it into the entry** ("unsure: ...") rather than guessing.
6. **`private/` stays private.** It is git-ignored. Read it when a question needs it. Never copy from it into `wiki/`, `archive/`, `commitments.md` or any other file.

---

## Wiki voice and structure

- Default tone: clear, factual, terse. `wiki/voice.md` overrides this where it says more.
- Keep the owner's own phrasing when it carries signal. Do not sand everything into neutral encyclopedia tone, and do not sand off doubts or negative parts.
- Headings only when an entry is long enough to need them. Bullets only when the content is a real list.
- One topic per file, kebab-case filenames.
- Keep `wiki/index.md` current when entries are added or renamed.

---

## Where things are

- `raw/` - inbox. Anything captured lands here first.
- `wiki/` - clean notes, one topic per file. Written by the loops, not by hand.
- `archive/` - processed raw files, never edited again.
- `projects/<name>/` - active work, each with a `README.md` digest.
- `drafts/` - things the brain writes for the owner to use. Never sent anywhere on its own.
- `commitments.md` - the ledger of who owes what to whom.
- `data/` - files the scheduled jobs write (today's brief, health).
- `prompts/` - the long prompts the loops and jobs run.
- `.claude/commands/` - the loops as slash commands: `/translate`, `/log`, `/today`, `/prep`, `/digest`, `/interview`.

From an agent other than Claude Code: open the command file and follow it, for example "read .claude/commands/today.md and do it".
