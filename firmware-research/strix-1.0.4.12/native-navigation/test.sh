#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ $# == 3 ]] || { echo 'Usage: bash test.sh /absolute/tested-TNV1.zip /absolute/rebuilt-candidate/payload /absolute/stock-payload'; exit 2; }
archive=$1; payload=$2; stock=$3
[[ "$archive" == /* && "$payload" == /* && "$stock" == /* ]] || exit 2
mkdir -p work
output=$(mktemp -d "$PWD/work/tests.XXXXXX")
source_root="$PWD/src/official-addon/research/navigation-runtime-v1"
music_headers="$(cd ../../../official-addon/music && pwd)"
flags=(-fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -Wno-incompatible-pointer-types -DTIO_DISPLAY_DIAGNOSTICS=1 -framework Foundation)
if [[ ${TIO_MUSIC:-0} == 1 ]]; then flags+=(-I "$music_headers"); cd music/phone; else cd phone; fi
common=(display_runtime.c display_client.c display_carrier.c DisplayDelta.c DisplayNavigation.m DisplayReplyObserver.m DisplayPhoneSession.m DisplayPhoneTransport.m DisplayDiagnostics.m ImageUpload.m ImageUploadTransport.m ExperimentalOTA.m ExperimentalOTAGuard.m ExperimentalOTAFlash.m nav_runtime.c NativeNavigation.m TNVTransport.m)
for name in DisplayDelta DisplayDeltaSession DisplayDiagnostics DisplayFramePacing DisplayNavigation DisplayPhone DisplayReplyObserver DisplayTaskBinding ImageUpload ImageUploadTransport NativeNavigation ExperimentalOTAGuard; do
  xcrun --sdk macosx clang "${flags[@]}" "${common[@]}" "${name}Tests.m" -o "$output/$name"
  if [[ "$name" == NativeNavigation ]]; then "$output/$name" "$output/navigation-trace.json"; else "$output/$name"; fi
done
for name in ExperimentalOTA ExperimentalOTADirectory ExperimentalOTAFlash; do
  xcrun --sdk macosx clang "${flags[@]}" "${common[@]}" "${name}Tests.m" -o "$output/$name"
done
"$output/ExperimentalOTA" "$archive" "$stock/nuttx_ap.bin"
"$output/ExperimentalOTADirectory" "$payload" "$stock"
"$output/ExperimentalOTAFlash" "$payload" "$stock"
for armed in 0 1; do
  xcrun --sdk macosx clang "${flags[@]}" -DTIO_OTA_FEED_ARMING_ENABLED="$armed" "${common[@]}" ExperimentalOTAFeed.m ExperimentalOTAFeedTests.m -o "$output/feed-$armed"
  "$output/feed-$armed" "$archive"
done
cd "$source_root"
for test in nav_test nav_view_test; do
  xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined nav_runtime.c nav_visual.c nav_view.c "$test.c" -o "$output/$test"
  "$output/$test"
done
echo "PASS local tests. Synthetic phone trace: $output/navigation-trace.json. No device IO."
