#!/bin/zsh
# Run a command against a mirror of LabKit outside iCloud (xcodebuild and SwiftPM hang or misbehave in the
# iCloud-synced folder). Each caller passes its own work name so parallel builds never share a mirror.
#
#   Tools/lk.sh <work-name> swift build
#   Tools/lk.sh <work-name> swift run -c release labkit-physcheck
#   Tools/lk.sh <work-name> env TOOLCHAINS=metal swift test --no-parallel
#   Tools/lk.sh <work-name> xcodebuild -scheme LabKit-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath ../dd build
#
# The mirror lives at ${LABKIT_BUILD_ROOT:-$TMPDIR}/labkit-<work-name>/LabKit and keeps its .build between runs.
set -e
NAME="${1:?work name}"; shift
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${LABKIT_BUILD_ROOT:-${TMPDIR:-/tmp}}/labkit-$NAME"
mkdir -p "$WORK/LabKit"
rsync -a --delete --exclude '.build' --exclude '.swiftpm' --exclude '* 2.*' --exclude '* 2' "$SRC/" "$WORK/LabKit/"
cd "$WORK/LabKit"
export CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/module-cache"
exec "$@"
