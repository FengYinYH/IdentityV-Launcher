#!/bin/bash
set -euo pipefail
# This installer is for disposable Actions VMs only; never install on a user's Mac.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || exit 64
mkdir -p "$RUNNER_TEMP/ci-ocr-metrics"
df -k "$RUNNER_TEMP" > "$RUNNER_TEMP/ci-ocr-metrics/disk-before.txt"
if ! command -v tesseract >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install tesseract
fi
IDV_CI_OCR_EXE="$(command -v tesseract)"
IDV_CI_OCR_DATA="$RUNNER_TEMP/ci-tessdata"
mkdir -p "$IDV_CI_OCR_DATA"
IDV_CI_OCR_ENG="$(brew --prefix tesseract)/share/tessdata/eng.traineddata"
if [[ ! -f "$IDV_CI_OCR_ENG" ]]; then
  IDV_CI_OCR_ENG="$(brew --prefix)/share/tessdata/eng.traineddata"
fi
cp "$IDV_CI_OCR_ENG" "$IDV_CI_OCR_DATA/eng.traineddata"
curl --fail --location --retry 2 --max-time 60 \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd/chi_sim.traineddata \
  --output "$IDV_CI_OCR_DATA/chi_sim.traineddata"
printf '%s  %s\n' a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730 "$IDV_CI_OCR_DATA/chi_sim.traineddata" | shasum -a 256 -c -
printf 'IDV_CI_TESSERACT=%s\nIDV_CI_TESSDATA_DIR=%s\nIDV_CI_OCR_FORCE_TESSERACT=1\n' "$IDV_CI_OCR_EXE" "$IDV_CI_OCR_DATA" >> "$GITHUB_ENV"
"$IDV_CI_OCR_EXE" --version
"$IDV_CI_OCR_EXE" --list-langs --tessdata-dir "$IDV_CI_OCR_DATA"

du -sk "$(brew --cellar tesseract)" "$IDV_CI_OCR_DATA" > "$RUNNER_TEMP/ci-ocr-metrics/selected-directories-kib.txt"
df -k "$RUNNER_TEMP" > "$RUNNER_TEMP/ci-ocr-metrics/disk-after.txt"
