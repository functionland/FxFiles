#!/bin/sh

# Xcode Cloud post-clone script for Flutter projects
# This script runs after the repository is cloned

set -e

echo "=== Xcode Cloud Post-Clone Script ==="

# Navigate to the root of the Flutter project
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Installing Flutter ==="
# Clone Flutter SDK
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"

echo "=== Flutter Version ==="
flutter --version

echo "=== Running flutter pub get ==="
flutter pub get

echo "=== Generating iOS build files ==="
flutter build ios --config-only --release --no-codesign

echo "=== Installing CocoaPods dependencies ==="
cd ios
pod install --repo-update

echo "=== Post-clone script completed ==="
