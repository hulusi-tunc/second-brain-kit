# Morning brief

You are running headless from the second brain repo. The owner is not watching. Today's date is in the invoking prompt. Read `wiki/voice.md` and `wiki/about-me.md` first.

The brief is one decision, not a list. Shape: the one thing to push forward today, then who is waiting, then one question.

## Gather, quietly

If a source is missing or a tool is unavailable, skip it silently.

1. `commitments.md`: rows `overdue` or `slipped`, rows whose Due is before today and not `done` (treat as overdue), rows due today or tomorrow.
2. `raw/`: count files other than `.gitkeep`.
3. `projects/*/README.md`: anything marked blocked or with a date this week.
4. `wiki/open-questions.md`: one unanswered question without the word Parked. Do not repeat yesterday's; yesterday's brief is in `data/brief.md`.
5. Slack: every MCP server named `slack-<workspace>` is one workspace (load their tools with ToolSearch first). In each, search the last day of DMs, group DMs and mentions of the owner; keep only messages where someone asked the owner something and the owner has not answered. Name the workspace on each `waiting:` line.
6. `data/fortune.json`: rows with status `new` and urgency `hot` or `soon` (what Slack shows heading the owner's way). A hot one can be the one thing.
7. If calendar or mail tools are available in this session, use them: today's events, unanswered mail that asks something of the owner.

## Choose the one thing

The single action that, done today, unblocks the most or costs the most if missed. A hard deadline beats everything; a person waiting beats solo work; due today beats due this week. Name the first concrete step, not the project: "send Sam the revised quote", not "move the client forward".

## Write it, exactly this shape

```
brief YYYY-MM-DD
one: <first step, under 12 words> | <why today, one clause> | <ledger id, if any>
day: HH:MM <event> | <who>          (only if a calendar was available, one line per event)
waiting: <person> | <what they want> | <since when, workspace if Slack> | <ledger id>
fortune: <text> | <move>          (at most 2, hot first, only if there are hot or soon ones)
raw: <N> notes waiting, run /translate          (only if N > 0)
ask: <the open question, one line>
```

- At most 3 `waiting:` lines, oldest first.
- Under 900 characters. No greeting, no emoji, no encouragement. Names, dates, numbers.

Write the message to `data/brief.md` with the Write tool, overwriting it, and print the same text to stdout. Edit nothing else.
