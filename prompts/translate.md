# Translate: raw/ into wiki/

Read everything in `raw/` (ignore `.gitkeep`). Update or create matching files in `wiki/` so the wiki reflects what is in `raw/`. Then move each processed file from `raw/` to `archive/` with the same filename. Never delete.

Read `wiki/voice.md` first and write in that voice.

## Rules

- One topic per file in `wiki/`, kebab-case filenames.
- Merge into existing entries, never overwrite blindly. Read the entry first.
- If a raw note relates to a folder in `projects/`, also surface it in that project's `README.md`.
- When uncertain, note it inside the entry ("unsure: ...") rather than guessing.
- If something answers a line in `wiki/open-questions.md`, record the answer in the right entry and strike the question through (`~~...~~`).
- Nothing from `private/` ever goes into the wiki.

## Keep the graph connected

The repo works as an Obsidian vault; the graph is built from these links.

- Every wiki file starts with frontmatter: `tags: [person]`, `[project]`, `[company]` or `[topic]`.
- A person, project or company that shows up on 3 or more wiki pages gets its own page: one or two lines on who or what it is, key facts with dates, then `Appears in:` with links to the pages that mention it.
- On every page you touch, link the first mention of each person, project or company that has a page. Relative markdown links only, `[Sam](sam.md)`, never `[[wikilinks]]`, so GitHub and every agent can follow them.
- Cite sources as links: `[meeting-2026-01-12-weekly](../archive/meeting-2026-01-12-weekly.md)`.

## Keep a Now block

- On every person, project and company page, right after the title (and a one or two line intro), comes `## Now`: 3 to 8 lines on where it stands today. Status, what is open and who owes what (from `commitments.md`), the next date that matters, the last contact with its date.
- Rewrite the Now block whenever you touch the page. History stays below it, dated, never deleted.

## Commitments

- Every promise in a raw note ("I'll send it Friday", a meeting's next steps) becomes a row in `commitments.md`: new ID, date, who owes, to whom, what, due if stated, status `open`, source file.
- A new ID: `python3 -c "import secrets; print('c' + secrets.token_hex(4)[:7])"`.
- If a later note shows the outcome, update the earlier row (`done`, `slipped`, `dropped`) instead of adding a duplicate.
- Speaker labels in transcripts are often wrong. Decide who owes from what is said, not from the label. If still unsure, put `?` after the name.

## Finish

- Add any new page to `wiki/index.md`.
- Stage only what you touched: `git add wiki/ raw/ archive/ commitments.md projects/`, then `git commit -m "translate: <N> raw files processed"`.
- Reply with the wiki entries created or updated, and anything you were unsure about.
