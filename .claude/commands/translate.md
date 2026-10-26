---
description: Merge everything in raw/ into wiki/, move it to archive/, commit
---
Run the translate loop in this repo.

1. If `raw/` is empty (ignore `.gitkeep`), say so and stop. Do not invent work.
2. Read `prompts/translate.md` and follow it exactly against everything in `raw/`.
3. Obey the hard rules in `CLAUDE.md`.
4. Reply with the wiki entries created or updated, and anything you were unsure about.
