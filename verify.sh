#!/bin/bash
# Offline core tests: endpointing, vocabulary and pinyin rules, settings
# compatibility, draft-engine rules. No network or API key needed.
# Usage: bash verify.sh [scenario.wav scenario.json]
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
OUT="$PROJECT_DIR/build"
S="$PROJECT_DIR/Sources"
CACHE="${MODULE_CACHE:-$OUT/module-cache}"  # override with MODULE_CACHE=/path if needed
mkdir -p "$CACHE"
/usr/bin/xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path "$CACHE" "$S/Models.swift" "$S/UtteranceSegmenter.swift" "$S/SpeechPipeline.swift" \
  "$S/AudioCapture.swift" "$S/TranslationClient.swift" "$S/SemanticEnvironment.swift" "$S/LocalDraftTranslator.swift" \
  "$PROJECT_DIR/Tests/CoreTests.swift" -o "$OUT/CoreTests"
"$OUT/CoreTests" "$@"
