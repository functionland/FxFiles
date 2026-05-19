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

# Flutter 3.44+ enabled Swift Package Manager by default. Most of this project's
# iOS plugins (workmanager_apple, video_thumbnail, sign_in_with_apple,
# coinbase_wallet_sdk, permission_handler_apple, open_filex, nsd_ios,
# image_cropper, google_mlkit_*, fula_client, flutter_contacts, fllama, ...)
# do NOT support SPM and fall back to CocoaPods. On Xcode Cloud, automatic
# package resolution is disabled and there's no checked-in Package.resolved,
# so the resolver refuses to add transitive SPM deps (e.g. DKImagePickerController
# pulled in by image_cropper) and the build fails at "Adding Swift Package
# Manager integration". Turn SPM off — Flutter's documented workaround for
# exactly this situation.
echo "=== Disabling Swift Package Manager (most iOS plugins don't support it) ==="
flutter config --no-enable-swift-package-manager

echo "=== Running flutter pub get ==="
flutter pub get

echo "=== Generating iOS build files ==="
flutter build ios --config-only --release --no-codesign

echo "=== Installing CocoaPods dependencies ==="
cd ios
pod install --repo-update

echo "=== Post-clone script completed ==="
