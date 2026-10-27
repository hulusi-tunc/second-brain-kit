# Working on the kit

This repo is the product: the code, prompts and app every second brain runs on. Your own brain (notes, wiki, ledger, Slack data) never comes here. It lives in your own private repo and pulls updates from this one.

## Branches

- `main` is what everyone gets. Nobody pushes to it directly; changes reach it through a pull request.
- Each of us works on our own branch (`hulusi`, `martin`). Push there as often as you like.
- When something on your branch is good, open a pull request to `main`. The other one looks, then either of us merges.
- Before a pull request, bring your branch up to date: `git pull origin main`.

## Before anything reaches main

- No personal data: no names of clients or colleagues, no Slack ids, no paths with your username, nothing from your own brain. Examples use made-up people (Sam, Maya, Northwind).
- Test it from zero: on a scratch brain made from this repo, not on your own.
- One change per commit, `type(scope): what`, then why.

## Your own brain, kept up to date

Make your brain from a clone, not from "Use this template", so it shares history with the kit and updates merge cleanly:

```bash
git clone https://github.com/hulusi-tunc/second-brain-kit.git ~/second-brain
cd ~/second-brain
git remote rename origin kit
git remote add origin git@github.com:<you>/<your-private-brain>.git
git push -u origin main
./setup.sh
```

Then, whenever the kit's `main` has something new:

```bash
git pull kit main
```

Your notes and the kit's code live in different files (`raw/`, `wiki/`, `archive/` and `commitments.md` are yours; `bin/`, `tools/`, `prompts/`, `home/`, `app/` are the kit's), so the pull merges on its own.
