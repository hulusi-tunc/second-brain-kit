# Second brain kit

A second brain that runs on [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and plain markdown files in a git repo.

You throw raw stuff in: a thought from the terminal, meeting notes, a document, the day's work. Claude turns it into a clean, linked wiki about your life and work, keeps a ledger of who owes what to whom, and gives you a short brief every morning. No app, no database, no account. Everything is files you own.

```
brain "Sam said the quote is fine if we ship by the 20th"
        │
        ▼
     raw/2026-01-12.md  ──/translate──▶  wiki/sam.md            (Now: quote agreed, ship by 20 Jan)
                                         commitments.md         (you owe Sam: ship by 2026-01-20)
                                         archive/2026-01-12.md  (the original, kept forever)
                                                │
                                   08:30 ──▶ brief: "one: confirm the 20th with Sam"
```

## Set up your own

1. Click **Use this template** at the top of this page, and make the new repo **Private**. Your notes go in it.
2. Clone it and run the setup:

   ```bash
   git clone git@github.com:<you>/<your-brain>.git ~/second-brain
   cd ~/second-brain
   ./setup.sh
   ```

   It asks a few lines about you, writes `brain.config`, links the `brain` command and lets you pick the scheduled jobs.
3. Start Claude Code in the folder and let it get to know you:

   ```bash
   claude
   /interview
   ```

Needs macOS or Linux, git, python3 and Claude Code. Node.js too, if you connect Slack. The scheduled jobs use launchd on macOS; on Linux `setup.sh` prints crontab lines instead.

## Use it

**Capture, anytime.** `brain "the thought"` from any terminal lands in `raw/<today>.md` with the time. `echo ... | brain` works too, and `brain` alone opens your editor. Anything else you drop in `raw/` counts: meeting notes, pasted chats, a PDF's text.

**Process.** `/translate` in Claude Code, or the nightly job does it for you. Each raw file is merged into the wiki, promises go into the ledger, and the file moves to `archive/`.

**Ask.** Open Claude Code in the folder and ask anything about your own past: "what did I decide about pricing in March?", "what do I owe Sam?".

**Before a meeting.** `/prep Sam`: last time, who owes what, three questions to ask.

**End of a session.** `/log` writes what the session taught the brain about you into the wiki.

| Command | What it does |
|---|---|
| `/translate` | `raw/` into `wiki/`, promises into `commitments.md`, files into `archive/`, commit |
| `/today` | the morning brief, on demand |
| `/prep <who>` | one-screen brief before a meeting |
| `/log` | save what this session taught about you |
| `/digest <project>` | summarize `projects/<project>/` into its README |
| `/interview [topic]` | Claude asks, one question at a time, and fills the wiki |
| `brain ls` | what is waiting in `raw/` |
| `brain done <id>` | mark a ledger row done |
| `brain health` | state of the scheduled jobs |
| `brain home` | Brain Home: the map of your people and projects, what is owed, what to review |
| `brain slack add <name>` | read one more Slack workspace (see Slack, below) |
| `brain fortune` | scan Slack now for what is heading your way |
| `brain watch <term>` | the fortune teller always looks for this |

## Brain Home

The dashboard of your brain, in [`home/`](home/): a dial with everyone and everything in your wiki, closer to the middle when it needs you, and a panel with Today, Week and Review (what Brain filed since yesterday, waiting for your yes). Click a name for what is owed both ways and the last call; mark things done, keep or drop them, and the ledger updates. `brain home` opens it in the browser; the Mac app opens it in its own window, with Ask built in.

## The Mac app

Optional, in [`app/`](app/README.md): it lives in the notch. Hold a key and talk to type anywhere, ask your brain a question out loud, and get notes with a summary after every call, all transcribed on your Mac. `setup.sh` offers to install it, or see [app/README.md](app/README.md).

## Folders

| Folder | What lives there |
|---|---|
| `raw/` | inbox. Everything lands here first |
| `wiki/` | clean notes, one topic per file, linked. Open the repo in Obsidian for the graph |
| `archive/` | processed raw files, never edited again |
| `projects/` | one folder per active project, each with a `README.md` digest |
| `drafts/` | things the brain writes for you to use. Never sent anywhere on its own |
| `private/` | git-ignored. Claude may read it when you ask, never copies it out |
| `commitments.md` | the ledger: who owes what to whom, by when |
| `data/` | what the jobs write: today's brief |
| `prompts/` | the long prompts behind the loops. Edit them to change behavior |
| `app/` | the Mac app, optional |
| `home/` | Brain Home, the dashboard |

## Scheduled jobs

All optional, all chosen in `setup.sh` (`./setup.sh jobs` to change them later). Each one runs Claude headless, so it uses your Claude usage.

| Job | When | What |
|---|---|---|
| translate | 23:55 | runs `/translate` on whatever is in `raw/` |
| brief | 08:30 | writes `data/brief.md` and shows one notification: the one thing for today |
| work | 23:40 | reads the day's Claude Code sessions and your git commits under `PROJECTS_DIR`, writes a work digest into `raw/` |
| sweep | 18:00 | copies documents from `INBOX_DIR` into `raw/` as text |
| wispr | 18:30 | only if you use Wispr Flow: finished meeting notes into `raw/` |

If a job hits a usage limit, every job pauses until the reset time instead of failing over and over. Three failures in a row send one notification. `brain health` shows the state, `brain resume` clears a pause.

If your repo has a remote, the jobs pull before and push after, so your phone (Claude Code in the Claude app, opened on the same repo) sees the same brain.

## Slack, every workspace

The Slack connector on claude.ai reaches one workspace. If you work across several (your company plus one per client), the brain runs one small read-only Slack server per workspace instead, so `/today`, `/prep`, the morning brief and plain questions see all of them.

Once per workspace:

1. Open [api.slack.com/apps](https://api.slack.com/apps), **Create New App**, **From a manifest**, pick the workspace, and paste [`slack/app-manifest.json`](slack/app-manifest.json). It asks only for read access: history, search, people. It cannot post.
2. **Install to Workspace**. Some workspaces only allow apps an admin has approved; then Slack sends the admin a request, and you continue once it is approved.
3. Copy the **User OAuth Token** (`xoxp-...`) from **OAuth & Permissions**.
4. In a terminal:

   ```bash
   brain slack add agency        # a short name you choose for this workspace
   ```

   Paste the token when asked. It is checked with Slack and kept in your macOS Keychain, never in a file.

Then `brain slack ls` shows every workspace and whether its token still works, and `brain slack remove <name>` takes one out. In Claude Code each workspace is a server called `slack-<name>`: ask "what did the Northwind team ask me this week?" and Claude searches the right one.

Uses [slack-mcp-server](https://github.com/korotovsky/slack-mcp-server) (MIT) through `npx`, so Node.js must be installed. Before you point it at a client's workspace, check that your agreement with them allows it.

## Fortune teller

Once Slack is connected, the fortune teller reads every workspace for what is heading your way before it arrives: a PM asking a BA to re-check the payment provider on a project you build, two people promising a client different dates, your project discussed in a channel you are not in, a client gone quiet, someone who needs exactly what you do. Each fortune comes with the proof (who said what, where), why it touches you, one move, and a short draft you can copy.

- `brain fortune` scans now; `setup.sh` can schedule it (08:00 the last 7 days, then 11, 14, 17 and 20 since the last scan).
- Fortunes show in Brain Home's Today list, grouped by person and project; hot ones also show a notification, and the morning brief names them.
- Mark one useful or noise in Brain Home: noise teaches the next scan to skip things like it.
- `brain watch "payment"` adds a word it always looks for; `brain unwatch` removes it.

It only reads Slack and never posts.

## Make it yours

- **Who you are and how it writes:** `wiki/about-me.md` and `wiki/voice.md`. Every loop reads them.
- **The rules:** `CLAUDE.md`. The hard rules (never delete raw or archive, merge never overwrite, private stays private) are what keep the brain trustworthy; change the rest freely.
- **Behavior:** the prompts in `prompts/` and the commands in `.claude/commands/` are plain markdown. Add a command by adding a file.
- **The brief with your calendar or mail:** connect those tools to your Claude account, then list them in `BRIEF_TOOLS` in `brain.config`.
- **Other agents:** `AGENTS.md` points any agent to the same rules. From Claude Desktop, Cursor or Codex: "read .claude/commands/today.md and do it".

## Privacy

Your notes live in your own repo, which should be private. Nothing here sends data anywhere except Claude, through your own Claude Code login. `private/` never enters git at all. Uninstall the jobs with `./setup.sh uninstall`; your notes stay untouched.

## License

MIT
