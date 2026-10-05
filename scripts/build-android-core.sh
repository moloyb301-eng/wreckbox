#!/bin/sh
# Builds the Rust engine for Android and drops it into the Flutter app's jniLibs.
set -e
cd "$(dirname "$0")/../core"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.2.12479018}"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 23 -o ../app/android/app/src/main/jniLibs build --release --lib
ls -la ../app/android/app/src/main/jniLibs/*/libwreckbox_core.so
