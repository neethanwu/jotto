#!/bin/sh
# Archive the iPhone app (with the watch app inside) and upload it to
# App Store Connect for TestFlight. Build number = UTC timestamp, so
# every upload is higher than the last.
set -eu
cd "$(dirname "$0")"
BUILD=$(date -u +%Y%m%d%H%M)
ARCHIVE=build/archive/Jotto-$BUILD.xcarchive
xcodegen generate
xcodebuild -project Jotto.xcodeproj -scheme Jotto -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
echo "Uploaded build $BUILD"
