#!/bin/sh

# Xcode Cloud post-clone script for Flutter projects
# This script runs after the repository is cloned

set -e

echo "=== Xcode Cloud Post-Clone Script ==="

# Navigate to the root of the Flutter project
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Installing Flutter ==="
# Clone Flutter SDK. Pin to the SAME version Android CI uses
# (.github/workflows/android-deploy.yml -> flutter-version: '3.38.5')
# so both platforms build against the same SDK. Tracking `stable` auto-upgrades
# to whatever Flutter ships next, which has broken builds twice already:
#   - 3.44.0 turned Swift Package Manager on by default (most plugins don't
#     support it; surfaced as "Could not resolve package dependencies").
#   - 3.44.0 also made IconData a `final class`, breaking any package that
#     subclasses it (e.g. icon-font plugins like lucide_icons), which is the
#     "IconData can't be extended outside of its library" error.
# Bump this version when intentionally upgrading; keep iOS and Android aligned.
FLUTTER_VERSION="3.38.5"
git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"
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
