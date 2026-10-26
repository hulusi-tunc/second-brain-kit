# Brain for Mac

The second brain's Mac app. It lives in the notch (or a small pill at the top of a screen without one) and does three things, all on your Mac:

- **Dictation.** Hold **right ⌥**, talk, let go: the text lands where the cursor is. Whisper large-v3-turbo runs on the GPU, so a 10 s take is written in under a second. Fillers ("um", "uh") and self-corrections ("at 3, no wait, at 4") are cleaned up; "new line" and "new paragraph" work.
- **Ask the brain.** Hold **right ⌥ and right ⌘** together and ask: "what do I owe Sam?". The notch shows what the brain reads, then the answer from your wiki and ledger. With text selected, say what to do with it instead ("make it shorter", "fix the grammar") and press Replace.
- **Brain Home.** The dashboard of your brain in its own window: the dial of people and projects, Today, Week and Review, and Ask. Open it from the notch (Brain Home), the menu bar, Spotlight, or `brain://home`. Done, keep and drop write straight to your ledger.
- **Call notes.** When a call app holds the mic (Meet, Zoom, Teams, Slack, FaceTime and others), the app records your mic and the call as two tracks. When the call ends, both are transcribed and a note lands in `raw/`, then Claude adds a title, a summary and next steps. Five minutes before a call in your calendar, the notch offers a prep card: last time, who owes what, what to ask.

Audio stays on your Mac (in `private/voice/`, git-ignored) and is deleted after 7 days. Only the text of a question or a transcript goes to Claude, through your own Claude Code login.

## Install

Needs a Mac with Apple silicon, macOS 26 or later, the Xcode command line tools (`xcode-select --install`), cmake (`brew install cmake`), and the kit already set up (`./setup.sh` in the repo root).

```bash
cd app
scripts/models.sh     # once: the Whisper and voice detection models, about 575 MB
scripts/build.sh      # builds, signs and installs ~/Applications/Brain.app, starts it at login
```

The first build also fetches and compiles whisper.cpp (a few minutes). Then allow **Microphone** and **Accessibility** when macOS asks (Accessibility is what lets it paste). For call notes, allow **System Audio Recording** on the first call; for the prep card, **Calendars**.

Signing: with an Apple Development certificate (free with an Apple ID in Xcode), the permissions survive rebuilds. Without one the app is signed ad-hoc and macOS asks again after every rebuild. `BRAIN_SIGN_IDENTITY` picks a certificate.

`scripts/build.sh --uninstall` removes the app and its launch agent. Your notes are untouched.

## Settings

Rest the pointer on the notch: it grows into quick actions (last answer, open your brain, warm mic) and **All settings** (record calls, music down while you talk, the two shortcuts). Everything else is a `defaults` line:

```bash
defaults write local.secondbrain.app languages -array en de    # the languages you speak; empty means any
defaults write local.secondbrain.app myName Sam                # your name on call notes (default: macOS first name)
defaults write local.secondbrain.app preferredMic "Shure"      # a mic to always pick first
defaults write local.secondbrain.app repo ~/my-brain           # if the app should use another brain folder
```

Spelling hints for names Whisper gets wrong go in `~/Library/Application Support/Brain/vocab.json`:

```json
{ "prompt": "Northwind, Okafor, Figma.", "replacements": [{ "from": "north wind", "to": "Northwind" }], "snippets": [] }
```

## From anywhere

- `brain://ask?q=what do I owe Sam` asks, `brain://save?text=call Sam back` saves a note to `raw/`. Use them from Shortcuts, Raycast or a link.
- **Ask Brain** and **Save to Brain** sit in every app's right-click Services menu.

## For testing

`.build/release/Brain --file take.wav` transcribes a file twice and prints the time. `--mic-test` checks the mic, `--agenda` shows the calendar as the app sees it, `--clean "text"` runs the clean-up rules. The log is `~/Library/Logs/Brain.log`.
