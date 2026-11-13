#!/bin/sh
# Builds the Qwen3-ASR asset pack that App Store Connect hosts for Jotto
# (Settings → Processing → Qwen3-ASR downloads it through the App Store,
# which reaches every storefront, mainland China included).
#
#   AssetPacks/qwen3-asr/package.sh
#   → build/assetpacks/qwen3-asr-0-6b.aar, to deliver with Transporter
#
# The files are the same pinned revisions SpeechPack.swift downloads from
# Hugging Face for builds outside the App Store and TestFlight. Both are
# Apache-2.0 (Qwen/Qwen3-ASR-0.6B and aufklarer/Qwen3-ASR-CoreML).
set -eu
cd "$(dirname "$0")/../.."
SRC=build/assetpacks/src/qwen3-asr-0.6b
mkdir -p "$SRC"

MODELS=https://huggingface.co/aufklarer/Qwen3-ASR-CoreML/resolve/8c6bc87b87856930b435550e94ce47de710ce4ed
TOKENIZER=https://huggingface.co/Qwen/Qwen3-ASR-0.6B/resolve/5eb144179a02acc5e5ba31e748d22b0cf3e303b0

fetch() { # base path size
  out="$SRC/$2"
  if [ -f "$out" ] && [ "$(stat -f %z "$out")" = "$3" ]; then return; fi
  mkdir -p "$(dirname "$out")"
  echo "  $2"
  curl -fsSL --retry 3 -o "$out" "$1/$2"
  [ "$(stat -f %z "$out")" = "$3" ] || { echo "size mismatch: $2" >&2; exit 1; }
}

echo "Fetching model files"
fetch $MODELS config.json 656
for part in decoder_part1:220344512:391638:10422:1263 decoder_part2:376233664:394840:10416:1257 \
            embedding:155583168:1161:1589:317 encoder:186844416:1298756:2736:376; do
  IFS=: read name weights mil meta core <<EOF2
$part
EOF2
  fetch $MODELS "$name.mlmodelc/analytics/coremldata.bin" 243
  fetch $MODELS "$name.mlmodelc/coremldata.bin" "$core"
  fetch $MODELS "$name.mlmodelc/metadata.json" "$meta"
  fetch $MODELS "$name.mlmodelc/model.mil" "$mil"
  fetch $MODELS "$name.mlmodelc/weights/weight.bin" "$weights"
done
fetch $TOKENIZER tokenizer_config.json 12487
fetch $TOKENIZER vocab.json 2776833

echo "Packaging"
xcrun ba-package package "$PWD/AssetPacks/qwen3-asr/Manifest.json" -o "$PWD/build/assetpacks/qwen3-asr-0-6b.aar"
ls -lh build/assetpacks/qwen3-asr-0-6b.aar
