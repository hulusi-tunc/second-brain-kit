#!/bin/bash
# One-time setup, safe to run again.
#   ./setup.sh            everything: about you, config, the brain command, scheduled jobs
#   ./setup.sh jobs       only (re)choose the scheduled jobs
#   ./setup.sh uninstall  remove the scheduled jobs and the brain command link
set -e
SB="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SB"
LABEL=local.second-brain
AGENTS="$HOME/Library/LaunchAgents"
MAC=0; [ "$(uname)" = Darwin ] && MAC=1

ask() { local a; read -r -p "$1${2:+ [$2]}: " a; echo "${a:-$2}"; }
confirm() { local a; read -r -p "$1 [${2:-y}/$( [ "${2:-y}" = y ] && echo n || echo y )]: " a; a="${a:-${2:-y}}"; [ "$a" = y ] || [ "$a" = Y ]; }

uninstall_jobs() {
  [ $MAC -eq 1 ] || return 0
  for p in "$AGENTS/$LABEL".*.plist; do
    [ -f "$p" ] || continue
    launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
    rm -f "$p"; echo "removed $(basename "$p")"
  done
}

# job name, script, hours (one, or several like 11,14,17), minute, optional argument for the script
install_job() {
  local name=$1 script=$2 h=$3 m=$4 arg=${5:-} p="$AGENTS/$LABEL.$1.plist"
  if [ $MAC -eq 0 ]; then
    echo "$m $h * * * /bin/bash $SB/bin/$script $arg    # add with: crontab -e"; return
  fi
  local when="" hh
  for hh in ${h//,/ }; do when="$when<dict><key>Hour</key><integer>$hh</integer><key>Minute</key><integer>$m</integer></dict>"; done
  mkdir -p "$AGENTS"
  cat > "$p" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL.$name</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SB/bin/$script</string>${arg:+<string>$arg</string>}</array>
  <key>StartCalendarInterval</key><array>$when</array>
  <key>StandardOutPath</key><string>/tmp/$LABEL.$name.out</string>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.$name.out</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$p"
  printf "  %-12s every day at %s:%02d\n" "$name" "$h" "$m"
}

choose_jobs() {
  echo; echo "Scheduled jobs. Each runs Claude headless on your account and uses your usage."
  uninstall_jobs >/dev/null
  [ $MAC -eq 0 ] && echo "Not on macOS: add these lines to your crontab instead."
  confirm "Nightly translate, raw/ into wiki/ at 23:55" && install_job translate brain-translate.sh 23 55
  confirm "Morning brief at 08:30 (a notification and data/brief.md)" && install_job brief brain-brief.sh 8 30
  confirm "Nightly work digest from your Claude Code sessions and commits at 23:40" n && install_job work brain-work.sh 23 40
  confirm "Daily sweep of documents from your inbox folder at 18:00" n && install_job sweep brain-sweep.sh 18 0
  if confirm "Fortune teller: scan Slack for what is heading your way, 08:00 deep, 11/14/17/20 quick (needs brain slack add)" n; then
    install_job fortune-deep brain-fortune.sh 8 0 deep
    install_job fortune brain-fortune.sh 11,14,17,20 0 quick
  fi
  if [ -d "$HOME/Library/Application Support/Wispr Flow" ]; then
    confirm "Wispr Flow found. Daily meeting notes into raw/ at 18:30" && install_job wispr brain-wispr.sh 18 30
  fi
}

case "$1" in
  uninstall) uninstall_jobs; rm -f "$HOME/.local/bin/brain"; echo "done. Your notes are untouched."; exit 0 ;;
  jobs) choose_jobs; exit 0 ;;
esac

echo "second brain setup, in $SB"; echo

# 1. tools
for t in git python3; do command -v $t >/dev/null || { echo "missing: $t, install it first"; exit 1; }; done
CLAUDE_PATH=$(command -v claude || true)
# the real file, not a per-shell shim (fnm, nvm, asdf), so launchd still finds it tomorrow
[ -n "$CLAUDE_PATH" ] && CLAUDE_PATH=$(readlink -f "$CLAUDE_PATH")
[ -z "$CLAUDE_PATH" ] && { echo "missing: claude (Claude Code). Install: https://docs.anthropic.com/en/docs/claude-code"; exit 1; }

# 2. about you, only while the placeholders are still there
if grep -q "{{NAME}}" wiki/about-me.md; then
  echo "A few lines about you. /interview in Claude Code goes deeper later."
  NAME=$(ask "Your name")
  ROLE=$(ask "What you do, one line")
  TOPICS=$(ask "Topics you think about, comma separated")
  LANGS=$(ask "Languages you write or dictate in" "English")
  TONE=$(ask "How the brain should write" "clear, factual, terse")
  NEVER=$(ask "Things it should never do" "motivational filler, hype, long entries")
  python3 - "$NAME" "$ROLE" "$TOPICS" "$LANGS" "$TONE" "$NEVER" <<'PY'
import sys
name, role, topics, langs, tone, never = sys.argv[1:]
for path, pairs in (("wiki/about-me.md", {"NAME": name, "ROLE": role, "TOPICS": topics, "LANGUAGES": langs}),
                    ("wiki/voice.md", {"TONE": tone, "NEVER": never})):
    s = open(path).read()
    for k, v in pairs.items():
        s = s.replace("{{" + k + "}}", v or "not set yet")
    open(path, "w").write(s)
PY
  echo
fi

# 3. config
if [ ! -f brain.config ]; then
  sed "s|^CLAUDE_BIN=\"\"|CLAUDE_BIN=\"$CLAUDE_PATH\"|" brain.config.example > brain.config
  PROJ=$(ask "Where your code projects live (for the work digest)" "$HOME/Projects")
  INBOX=$(ask "A folder you drop documents into (for the sweep)" "$HOME/Inbox")
  sed -i.bak "s|^PROJECTS_DIR=.*|PROJECTS_DIR=\"$PROJ\"|; s|^INBOX_DIR=.*|INBOX_DIR=\"$INBOX\"|" brain.config && rm -f brain.config.bak
  mkdir -p "$INBOX"
  echo "wrote brain.config (edit it any time)"
fi

# 4. the brain command
chmod +x bin/*
mkdir -p "$HOME/.local/bin"
ln -sf "$SB/bin/brain" "$HOME/.local/bin/brain"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
  echo "add this to your ~/.zshrc so 'brain' works everywhere:"; echo '  export PATH="$HOME/.local/bin:$PATH"' ;; esac
echo "linked: brain -> ~/.local/bin/brain"

# 5. jobs
choose_jobs

# 6. the Mac app (optional)
if [ $MAC -eq 1 ] && [ "$(uname -m)" = arm64 ]; then
  echo
  if confirm "Install the Mac app too (dictation, ask from the notch, call notes; downloads 575 MB)" n; then
    (cd app && scripts/models.sh && scripts/build.sh) || echo "app not installed, see app/README.md"
  fi
fi

# 7. commit your details into your own repo
git add wiki/about-me.md wiki/voice.md 2>/dev/null && { git diff --cached --quiet || git commit -q -m "setup: about me"; } || true

cat <<EOF

Ready. Try:
  brain "first thought in my second brain"
  brain ls
  claude          (from this folder), then /interview, then /translate

Health of the jobs: brain health. Log: ~/Library/Logs/second-brain.log
EOF
