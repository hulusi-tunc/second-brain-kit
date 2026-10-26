---
description: Before a meeting - last time, who owes what, what to ask
argument-hint: <person | company | project>
---
Pre-meeting brief about `$ARGUMENTS`. One screen, terse. If no argument was given, ask who.

Pull from:
1. `commitments.md`: every row where `$ARGUMENTS` owes or is owed and status is not `done`. Overdue first.
2. `archive/`: grep the name, open the last 3 matching files, read only the summary and next steps.
3. `wiki/`: the matching entry, if one exists.
4. Slack: every `slack-<workspace>` server (one per workspace). Search each for this person or project, last 7 days. Name the workspace when you quote it.
5. Any other connected mail or tracker tool: the last 7 days with this person or project.

Answer in this order, nothing else:
- **Last time**: date and one line on what was agreed.
- **They owe you**: from the ledger, overdue first, with dates.
- **You owe them**: same.
- **Ask**: 3 questions max, specific, built from the gaps above.
- **Expect**: what they will probably raise.

If a source has nothing, skip it. Never invent.
