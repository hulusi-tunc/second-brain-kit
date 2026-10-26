#!/bin/bash
# Builds vendor/whisper.cpp (static, Metal) with one patch for the app to link: with the language
# on auto, stock whisper.cpp encodes the audio twice (once to detect the language, once to
# transcribe); the patch reuses the first encode, so a dictation lands in about half the time.
# The commit is pinned, so the patch always applies.
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER_COMMIT=6e4ab854f67f743900934a703d5603419384c961
command -v cmake >/dev/null || { echo "needs cmake: brew install cmake"; exit 1; }
if [ ! -d vendor/whisper.cpp/.git ]; then
  mkdir -p vendor/whisper.cpp && cd vendor/whisper.cpp
  git init -q && git remote add origin https://github.com/ggml-org/whisper.cpp.git
  git fetch -q --depth 1 origin "$WHISPER_COMMIT" && git checkout -q FETCH_HEAD
  cd ../..
fi
cd vendor/whisper.cpp
grep -q "brain patch" src/whisper.cpp || git apply ../../scripts/whisper-onepass.patch
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null
cmake --build build -j "$(sysctl -n hw.ncpu)" --config Release --target whisper >/dev/null
echo "whisper.cpp built: $(git rev-parse --short HEAD), patched"
