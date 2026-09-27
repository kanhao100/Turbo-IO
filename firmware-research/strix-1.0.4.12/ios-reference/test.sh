#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ $# == 2 ]] || { echo 'Usage: bash test.sh /absolute/R3.zip /absolute/exact-R3-payload-directory'; exit 2; }
archive=$1
payload=$2
[[ "$archive" == /* && "$payload" == /* ]] || { echo 'Explicit absolute inputs required'; exit 2; }
mkdir -p ../work
output=$(mktemp -d ../work/ios-tests.XXXXXX)
flags=(-fobjc-arc -fmodules -Wall -Wextra -Werror -framework Foundation)
xcrun --sdk macosx clang "${flags[@]}" ExperimentalOTAGuard.m ExperimentalOTAGuardTests.m -o "$output/guard"
"$output/guard"
xcrun --sdk macosx clang "${flags[@]}" ExperimentalOTA.m ExperimentalOTAGuard.m ExperimentalOTAFlash.m ExperimentalOTAFlashTests.m -o "$output/flash"
"$output/flash" "$payload"
xcrun --sdk macosx clang "${flags[@]}" ExperimentalOTA.m ExperimentalOTATests.m -o "$output/import"
"$output/import" "$archive"
for armed in 0 1; do
  xcrun --sdk macosx clang "${flags[@]}" -DTIO_OTA_FEED_ARMING_ENABLED="$armed" ExperimentalOTA.m ExperimentalOTAGuard.m ExperimentalOTAFlash.m ExperimentalOTAFeed.m ExperimentalOTAFeedTests.m -o "$output/feed-$armed"
  "$output/feed-$armed" "$archive"
done
