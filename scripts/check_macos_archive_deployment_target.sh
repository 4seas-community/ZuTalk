#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:?usage: check_macos_archive_deployment_target.sh <archive> <maximum-macos-version>}"
MAXIMUM_VERSION="${2:?usage: check_macos_archive_deployment_target.sh <archive> <maximum-macos-version>}"

[[ -f "$ARCHIVE" ]] || { echo "FAIL: macOS archive does not exist: $ARCHIVE" >&2; exit 1; }
[[ "$MAXIMUM_VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] \
    || { echo "FAIL: invalid macOS deployment target: $MAXIMUM_VERSION" >&2; exit 1; }

if ! SUMMARY="$(xcrun otool -l "$ARCHIVE" | awk -v ceiling="$MAXIMUM_VERSION" '
function version_rank(version, parts, count) {
    count = split(version, parts, ".")
    return (parts[1] + 0) * 1000000 + (parts[2] + 0) * 1000 + (parts[3] + 0)
}
/^.*\.a\(.*\):$/ {
    member = $0
    sub(/^.*\.a\(/, "", member)
    sub(/\):$/, "", member)
    next
}
$1 == "cmd" && $2 == "LC_BUILD_VERSION" {
    wanted = "minos"
    next
}
$1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" {
    wanted = "version"
    next
}
wanted != "" && $1 == wanted {
    version = $2
    records++
    if (version_rank(version) > version_rank(ceiling)) {
        unsafe++
        print "FAIL: " member " requires macOS " version ", maximum is " ceiling
    }
    wanted = ""
}
END {
    if (records == 0) {
        print "FAIL: no Mach-O deployment records found in archive"
        exit 2
    }
    if (unsafe > 0) {
        print "FAIL: " unsafe " archive member(s) require macOS newer than " ceiling
        exit 1
    }
    print "checked " records " Mach-O deployment records; none exceed macOS " ceiling
}
')"; then
    echo "$SUMMARY" >&2
    exit 1
fi

echo "✓ $(basename "$ARCHIVE"): $SUMMARY"
