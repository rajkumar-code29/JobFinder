#!/bin/bash
# Build the iOS app and upload it to App Store Connect / TestFlight (uses the Apple account signed in to Xcode).
# Run from app/:  ./tool/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER=$(date -u +%y%m%d%H%M)   # must increase with every upload
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
flutter build ipa --release --dart-define-from-file=env.json \
  --export-options-plist=ios/ExportOptions-upload.plist --build-number="$BUILD_NUMBER" 2>&1 | tee "$LOG"
# flutter exits 0 even when the export/upload step fails, so check its output
if grep -qE "Encountered error while creating the IPA|error: exportArchive" "$LOG"; then
  echo "Upload failed (see the errors above). A 'PLA Update available' error means the new Apple Developer"
  echo "agreement has to be accepted at developer.apple.com/account first."
  exit 1
fi
echo "Uploaded build $BUILD_NUMBER. It shows up in TestFlight once Apple finishes processing (~5-15 min)."
