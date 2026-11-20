# Second brain kit

Write things down the way they come. Claude files them into a wiki about your work, keeps a ledger of who owes what to whom, and tells you each morning the one thing that matters.

It runs on [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and plain markdown in a private git repo you own. No app, no database, no account.

```
brain "Sam said the quote is fine if we ship by the 20th"
        │
        ▼
     raw/2026-01-12.md  ──/translate──▶  wiki/sam.md            Now: quote agreed, ship by 20 Jan
                                         commitments.md         you owe Sam: ship by 2026-01-20
                                         archive/2026-01-12.md  the original, kept forever
                                                │
                                   08:30 ──▶ brief: "One: confirm the 20th with Sam."
```

## Start here

**New to it? Open [the first hour](docs/onboarding.html)**: one note's trip through the brain, then seven steps from clone to your first morning brief, with every command ready to copy. Clone the repo and open `docs/onboarding.html` in your browser.

The short version:

1. Make an **empty private repo** on GitHub for your notes.
2. Clone the kit and point it there. Clone it, don't use "Use this template": a clone keeps the kit's history, so updates merge by themselves later.

   ```bash
   git clone https://github.com/hulusi-tunc/second-brain-kit.git ~/second-brain
   cd ~/second-brain
   git remote rename origin kit
   git remote add origin git@github.com:<you>/<your-brain>.git
   git push -u origin main
   ./setup.sh
   ```

3. Capture something, then let Claude get to know you:

   ```bash
   brain "first thought in my second brain"
   claude        # in the folder, then: /interview, then /translate
   ```

Needs macOS or Linux, git, python3 and Claude Code. Node.js too if you connect Slack. The Mac app needs Apple silicon.

## Every day

| | |
|---|---|
| `brain "..."` | capture anything, from any terminal |
| `/translate` | raw notes into the wiki and the ledger (runs by itself at 23:55) |
| `/today` | the morning brief (arrives by itself at 08:30) |
| `/prep Sam` | one screen before a call: last time, who owes what, what to ask |
| `/log` | at the end of a session, keep what it taught the brain about you |
| `brain done c3f9a21b` | close a promise |
| `brain health` | are the scheduled jobs fine |

Ask anything in plain words too, from Claude Code in the folder: "what did I decide about pricing in March?"

## What else is in the box

- **Brain Home**: a dashboard of your people and projects, what is owed, what to review. `brain home`
- **Slack**: one read-only connection per workspace, so the brief and `/prep` see your chats.
- **Fortune teller**: reads Slack for what is heading your way before it arrives.
- **The Mac app** ([app/](app/README.md)): dictation anywhere, ask your brain out loud, notes after every call, all transcribed on your Mac.
- **Your phone**: open the same private repo in Claude Code in the Claude app.

All of it, with every command and setting: **[the guide](docs/guide.md)**.

## The rules that keep it trustworthy

Nothing is deleted from `raw/` or `archive/`. The wiki is merged, never overwritten. When Claude isn't sure, it says so in the entry. `private/` never enters git. They live in [CLAUDE.md](CLAUDE.md); change anything else freely.

## Getting kit updates

Your notes (`raw/`, `wiki/`, `archive/`, `commitments.md`) and the kit's code (`bin/`, `tools/`, `prompts/`, `home/`, `app/`) live in different folders, so this merges on its own:

```bash
git pull kit main
```

Want to change the kit itself? [CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy

Your notes live in your own private repo. Nothing here sends data anywhere except to Claude, through your own Claude Code login. `./setup.sh uninstall` removes the jobs; your notes stay.

## License

MIT
