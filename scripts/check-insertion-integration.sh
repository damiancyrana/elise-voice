#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TEST_DIR="$(mktemp -d)"
HOST_PID=""
function cleanup {
    [[ -z "$HOST_PID" ]] || kill "$HOST_PID" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
cd "$ROOT"
APP="$TEST_DIR/EliseInsertionHost.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.elisevoice.insertion-test</string>
<key>CFBundleExecutable</key><string>Host</string>
<key>CFBundleName</key><string>Elise Insertion Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    Tests/InsertionIntegration/Host.swift -o "$APP/Contents/MacOS/Host"
swiftc -emit-library -emit-module -module-name EliseVoiceCore \
    Sources/EliseVoiceCore/TextInsertionPolicy.swift Sources/EliseVoiceCore/PerformanceDiagnostics.swift \
    -o "$TEST_DIR/libEliseVoiceCore.dylib" -emit-module-path "$TEST_DIR/EliseVoiceCore.swiftmodule"
swiftc -parse-as-library -swift-version 6 -warnings-as-errors -I "$TEST_DIR" -L "$TEST_DIR" -lEliseVoiceCore \
    Sources/EliseVoice/TextInserter.swift Tests/InsertionIntegration/Check.swift -o "$TEST_DIR/check"
"$APP/Contents/MacOS/Host" "$TEST_DIR" > "$TEST_DIR/host.log" 2>&1 &
HOST_PID=$!
"$TEST_DIR/check" "$TEST_DIR" "$HOST_PID"
