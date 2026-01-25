#!/bin/bash
# Build HideMount Zygisk module for NoMount
# Requires Android NDK

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/zygisk-src"
OUT_DIR="$SCRIPT_DIR/module/zygisk"

# Find NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -d "$HOME/Android/Sdk/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Android/Sdk/ndk"/* 2>/dev/null | tail -1)
    elif [ -d "/opt/android-ndk" ]; then
        ANDROID_NDK_HOME="/opt/android-ndk"
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME environment variable."
    exit 1
fi

echo "Using NDK: $ANDROID_NDK_HOME"

CMAKE_TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"

build_arch() {
    local ARCH=$1
    local ABI=$2
    local BUILD_DIR="$SCRIPT_DIR/build-zygisk-$ARCH"

    echo "Building for $ABI..."

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cmake -B "$BUILD_DIR" -S "$SRC_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-26 \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build "$BUILD_DIR" -j$(nproc)

    mkdir -p "$OUT_DIR"
    cp "$BUILD_DIR/libhidemount.so" "$OUT_DIR/$ABI.so"

    echo "Built: $OUT_DIR/$ABI.so"
}

build_arch arm64 arm64-v8a
build_arch arm armeabi-v7a

echo ""
echo "Zygisk module built successfully!"
ls -la "$OUT_DIR"
