#!/bin/bash
# Build the iOS app and upload it to App Store Connect / TestFlight (uses the Apple account signed in to Xcode).
# Run from app/:  ./tool/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER=$(date -u +%y%m%d%H%M)   # must increase with every upload
flutter build ipa --release --dart-define-from-file=env.json \
  --export-options-plist=ios/ExportOptions-upload.plist --build-number="$BUILD_NUMBER"
echo "Uploaded build $BUILD_NUMBER. It shows up in TestFlight once Apple finishes processing (~5-15 min)."
