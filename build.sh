#!/bin/zsh
set -eu

if [[ $# -lt 1 || $# -gt 2 || "$1" != /* || "$1" != *.app || -e "$1" || -L "$1" ]]; then
  print -u2 'Usage: zsh build.sh /absolute/path/to/Ram\ Meter.app [bundle-id]'
  exit 64
fi

source_directory=${0:A:h}
destination=$1
bundle_id=${2:-app.rammeter.mac}
if [[ ! "$bundle_id" =~ '^[A-Za-z0-9][A-Za-z0-9.-]+$' ]]; then
  print -u2 'Invalid bundle identifier.'
  exit 64
fi
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ram-meter-build.XXXXXXXX")
trap '/bin/rm -rf -- "$temporary"' EXIT
bundle="$temporary/Ram Meter.app"
resources="$bundle/Contents/Resources"
iconset="$temporary/RamMeter.iconset"

/bin/mkdir -p "$bundle/Contents/MacOS" "$resources" "$iconset"
/bin/cp "$source_directory/Sources/Info.plist" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$bundle/Contents/Info.plist"
/bin/cp "$source_directory/Sources/runner_metrics.py" "$resources/runner_metrics.py"
/usr/bin/sips -s format png "$source_directory/Assets/ram-mark.svg" --out "$resources/RamMark.png" >/dev/null
/usr/bin/sips -s format png "$source_directory/Assets/app-icon.svg" --out "$temporary/icon.png" >/dev/null
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$temporary/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$temporary/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$resources/RamMeter.icns"
compile_meter() {
  /usr/bin/swiftc -O -swift-version 5 -target "$1-apple-macosx14.0" \
    "$source_directory/Sources/HostMetrics.swift" "$source_directory/Sources/Registration.swift" \
    "$source_directory/Sources/Monitor.swift" "$source_directory/Sources/WorkloadMeter.swift" \
    -o "$2"
}
executable="$bundle/Contents/MacOS/WorkloadMeter"
if [[ ${RAM_METER_UNIVERSAL:-0} == 1 ]]; then
  compile_meter arm64 "$temporary/arm64"
  compile_meter x86_64 "$temporary/x86_64"
  /usr/bin/lipo -create "$temporary/arm64" "$temporary/x86_64" -output "$executable"
else
  compile_meter "$(/usr/bin/uname -m)" "$executable"
fi
/usr/bin/codesign --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/bin/mv -n "$bundle" "$destination"
[[ ! -e "$bundle" ]]
