#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/srt-ios"
OUTPUT_DIR="$ROOT_DIR/deps/srt-ios"
SRT_TAG="${SRT_TAG:-v1.5.6}"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

git clone --depth 1 --branch "$SRT_TAG" https://github.com/Haivision/srt.git "$BUILD_DIR/srt"
git clone --depth 1 https://github.com/krzyzanowskim/OpenSSL "$BUILD_DIR/srt/scripts/build-ios/OpenSSL"

export PROCAM_SRT_BUILD_DIR="$BUILD_DIR"
python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["PROCAM_SRT_BUILD_DIR"]) / "srt" / "scripts" / "build-ios"
for name in ("mkssl-xcf.sh", "mksrt-xcf.sh"):
    path = root / name
    text = path.read_text()
    text = text.replace('BASE_DIR=$(readlink -f $0 | xargs dirname)', 'BASE_DIR=$(cd "$(dirname "$0")" && pwd)')
    path.write_text(text)

mkssl = root / "mkssl-xcf.sh"
text = mkssl.read_text()
text = text.replace(
"""xcodebuild -create-xcframework \\
 -library $SSL_DIR/iphoneos/lib/libcrypto.a \\
 -library $SSL_DIR/iphonesimulator/lib/libcrypto.a \\
 -library $SSL_DIR/appletvos/lib/libcrypto.a \\
 -library $SSL_DIR/appletvsimulator/lib/libcrypto.a \\
 -output $BASE_DIR/libcrypto.xcframework""",
"""xcodebuild -create-xcframework \\
 -library $SSL_DIR/iphoneos/lib/libcrypto.a -headers $SSL_DIR/iphoneos/include \\
 -library $SSL_DIR/iphonesimulator/lib/libcrypto.a -headers $SSL_DIR/iphonesimulator/include \\
 -output $BASE_DIR/libcrypto.xcframework"""
)
mkssl.write_text(text)

mksrt = root / "mksrt-xcf.sh"
text = mksrt.read_text()
start = text.index("ios_archs=(")
end = text.index("rm -rf $out", start)
text = text[:start] + """ios_archs=('arm64' 'arm64' 'x86_64')
ios_platforms=('OS' 'ARM_SIMULATOR' 'SIMULATOR64')
ios_targets=('iOS-arm64' 'iOS-simArm' 'iOS-simIntel64')
ssl_folders=('iphoneos' 'iphonesimulator' 'iphonesimulator')
""" + text[end:]
text = text.replace(
"""lipo -create $out/iOS-simArm/lib/$lib $out/iOS-simIntel64/lib/$lib -output $out/libsrt-ios-sim.a
lipo -create $out/tvOS_simArm/lib/$lib $out/tvOS_simIntel64/lib/$lib -output $out/libsrt-tv-sim.a
""",
"""lipo -create $out/iOS-simArm/lib/$lib $out/iOS-simIntel64/lib/$lib -output $out/libsrt-ios-sim.a
"""
)
text = text.replace(
"""xcodebuild -create-xcframework \\
 -library $out/iOS-arm64/lib/$lib -headers $srt_headers \\
 -library $out/libsrt-ios-sim.a -headers $srt_headers \\
 -library $out/tvOS/lib/$lib -headers $srt_headers \\
 -library $out/libsrt-tv-sim.a -headers $srt_headers \\
 -output $BASE_DIR/libsrt.xcframework""",
"""xcodebuild -create-xcframework \\
 -library $out/iOS-arm64/lib/$lib -headers $srt_headers \\
 -library $out/libsrt-ios-sim.a -headers $srt_headers \\
 -output $BASE_DIR/libsrt.xcframework"""
)
mksrt.write_text(text)

openssl_build = root / "OpenSSL" / "scripts" / "build.sh"
text = openssl_build.read_text()
text = text.replace(
"""build_watchos
build_appletvos
build_ios
build_visionos
build_macos
build_catalyst""",
"build_ios"
)
openssl_build.write_text(text)
PY

chmod +x "$BUILD_DIR/srt/scripts/build-ios/mkssl-xcf.sh"
chmod +x "$BUILD_DIR/srt/scripts/build-ios/mksrt-xcf.sh"

pushd "$BUILD_DIR/srt/scripts/build-ios"
./mkssl-xcf.sh
./mksrt-xcf.sh
popd

cp -R "$BUILD_DIR/srt/scripts/build-ios/libcrypto.xcframework" "$OUTPUT_DIR/"
cp -R "$BUILD_DIR/srt/scripts/build-ios/libsrt.xcframework" "$OUTPUT_DIR/"

echo "Built SRT iOS dependencies into $OUTPUT_DIR"
