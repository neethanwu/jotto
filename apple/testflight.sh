#!/bin/sh
# Archive the iPhone app (with the watch app inside) and upload it to
# App Store Connect for TestFlight. Build number = UTC timestamp, so
# every upload is higher than the last.
#
# Signs in with Xcode's account, or with an App Store Connect API key when
# ASC_KEY_ID and ASC_ISSUER_ID are set (the key itself at ASC_KEY_PATH, by
# default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
set -eu
cd "$(dirname "$0")"
BUILD=$(date -u +%Y%m%d%H%M)
ARCHIVE=build/archive/Jotto-$BUILD.xcarchive
xcodegen generate
xcodebuild -project Jotto.xcodeproj -scheme Jotto -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive
if [ -n "${ASC_KEY_ID:-}" ]; then
  set -- -authenticationKeyPath "${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}" \
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates ${1+"$@"}
echo "Uploaded build $BUILD"
