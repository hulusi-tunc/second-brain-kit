#!/bin/bash
# Downloads the two models the app needs into ~/.second-brain/models (about 575 MB), checked by size
# and SHA-256. Safe to run again: what is already there is kept.
#   ggml-large-v3-turbo-q5_0.bin   Whisper large-v3-turbo, quantized: dictation and call notes
#   ggml-silero-v5.1.2.bin         Silero voice detection: where speech is in a long recording
set -euo pipefail
DIR="$HOME/.second-brain/models"; mkdir -p "$DIR"
get() {
  local name=$1 url=$2 sha=$3 f="$DIR/$1"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ]; then echo "have $name"; return; fi
  echo "downloading $name"
  curl -fL --progress-bar -o "$f.part" "$url"
  [ "$(shasum -a 256 "$f.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$f.part"; echo "checksum mismatch for $name, not kept"; exit 1; }
  mv "$f.part" "$f"
}
get ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin \
  394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
get ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin \
  29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf
echo "models ready in $DIR"
