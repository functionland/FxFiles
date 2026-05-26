# iOS Share Extension — Xcode setup

The Shelf feature's iOS Share Extension (Session 4 of
[the Shelf plan](../../.claude/plans/i-want-to-add-buzzing-anchor.md))
needs a one-time Xcode target setup that can't be expressed in the
Flutter source tree. The source files are already in place at
`ios/ShelfShareExtension/`; the steps below wire them into the Xcode
project + the Apple Developer Portal.

**Do this once per developer machine. Skipping any step leaves the
Share Extension invisible to the system share sheet or unable to
write into the App Group container.**

---

## 1 · Open the workspace

```sh
cd ios
pod install                 # in case `image_picker` pulled new pods
open Runner.xcworkspace
```

Always use `Runner.xcworkspace`, not `Runner.xcodeproj` — Cocoapods
links don't load from the bare project.

## 2 · Add a new Share Extension target

In Xcode:

1. **File ▸ New ▸ Target…**
2. iOS tab → **Share Extension** → **Next**.
3. Product Name: `ShelfShareExtension`.
   - Bundle Identifier should auto-fill to
     `land.fx.files.ShelfShare` (must match
     `ShareViewController.appGroupIdentifier`'s parent bundle id +
     the Xcode setup checked in below).
4. Language: **Swift**.
5. Embed in Application: **Runner**.
6. **Finish**.
7. When Xcode prompts "Activate "ShelfShareExtension" scheme?" choose
   **Cancel** — you'll continue to build via `Runner`.

Xcode auto-creates a default `ShareViewController.swift` +
`Info.plist` + `MainInterface.storyboard` in a new
`ShelfShareExtension/` group. **Delete all three of them** from both
disk and the Xcode project. They'll be replaced by the checked-in
files.

## 3 · Add the checked-in source files to the new target

Right-click the `ShelfShareExtension` group in the Xcode navigator →
**Add Files to "Runner"…** and select:

- `ios/ShelfShareExtension/Info.plist`
- `ios/ShelfShareExtension/ShelfShareExtension.entitlements`
- `ios/ShelfShareExtension/ShareViewController.swift`

Make sure **only `ShelfShareExtension`** is checked in the target
membership panel for all three files (NOT `Runner`).

Then, in the `ShelfShareExtension` target's **Build Settings**:

- Search for **Info.plist File** → set it to
  `ShelfShareExtension/Info.plist`.
- Search for **Code Signing Entitlements** → set it to
  `ShelfShareExtension/ShelfShareExtension.entitlements`.

Delete the auto-generated `MainInterface.storyboard` reference if it
still appears in the target — `ShareViewController` is a custom
headless `UIViewController`, no storyboard needed. Also remove the
`NSExtensionMainStoryboard` key from `Info.plist` if Xcode tried to
keep it (the checked-in plist uses `NSExtensionPrincipalClass`
instead).

## 4 · Link required frameworks

In the `ShelfShareExtension` target's **General ▸ Frameworks and
Libraries**, add:

- `Foundation` (usually auto-linked)
- `UIKit`
- `UniformTypeIdentifiers`
- `UserNotifications`

`MobileCoreServices` is NOT needed — the checked-in code uses the
modern `UniformTypeIdentifiers` API (revision R12).

## 5 · Configure the App Group in the Apple Developer Portal

Both `Runner` (main app, bundle id `land.fx.files` / dev variant) and
`ShelfShareExtension` (`land.fx.files.ShelfShare` / dev variant) need
to share an App Group named exactly **`group.land.fx.files`**.

1. https://developer.apple.com/account → Identifiers → **+** →
   **App Groups** → name + identifier `group.land.fx.files` → continue.
2. Identifiers → click **`land.fx.files`** (main app) → enable
   **App Groups** → check `group.land.fx.files` → Save.
3. Identifiers → click **`land.fx.files.ShelfShare`** (extension; create
   if it doesn't exist yet — Xcode auto-creates on first build) →
   enable **App Groups** → check `group.land.fx.files` → Save.
4. Profiles → regenerate the development + distribution profiles for
   both bundles so the new entitlement lands. Download + double-click
   to install.

In Xcode, **Signing & Capabilities** for both targets should now show
**App Groups → group.land.fx.files** with a green checkmark.

The checked-in `Runner.entitlements` + `ShelfShareExtension.entitlements`
already declare the App Group; Xcode just needs the matching portal
config to sign with the new entitlement.

## 6 · Verify the BGTask identifier is permitted

The main app's `Runner/Info.plist` already lists
`land.fx.files.dump` in `BGTaskSchedulerPermittedIdentifiers` (checked
in during Session 4). No further work — Xcode reads this on build.

Note: `BGTaskScheduler.shared.register` MUST run before
`UIApplication.didFinishLaunching` returns. The checked-in
`AppDelegate.swift` does this; don't move the registration.

## 7 · Verify Privacy Nutrition Labels

Before the next App Store submission, update the privacy declaration
to reflect the Shelf feature's data handling:

- **Data linked to user**: user-content files (shared via the share
  sheet), URL metadata fetched for link previews.
- **Data not linked to user**: image classification labels generated
  by Google ML Kit on-device, exposed in autoDescription strings.
- **Tracking**: none.

The link enrichment HTTP fetch (R14 SSRF guards in
`ShelfEnricher`) makes outbound requests to URLs the user shares,
which is a third-party network exposure. Disclose accordingly.

## 8 · Build & smoke

```sh
flutter build ios --debug --no-codesign        # quick compile check
flutter run -d <ios-device>                    # interactive smoke
```

Once running on a real device:

1. Open Photos.app → pick an image → **Share** → "FxFiles Shelf"
   should appear in the third row of share targets.
2. Tap it. The Share Extension fires headlessly (no compose UI).
   Expect a "FxFiles Shelf — Queued 1 item…" notification within ~1 s.
3. Switch back to FxFiles. The lifecycle observer drains the App
   Group container; the Shelf tile appears in `/shelf` within a few
   seconds; the queued notification is replaced by "Saved to Shelf: …".

If step 1 fails: re-check step 4 (frameworks) + step 5 (App Group)
and `Info.plist`'s `NSExtensionActivationRule` accepts the content
type.

If step 2 fails (sheet appears but no notification): the user hasn't
granted notification permission yet. Open FxFiles once first — the
main app's `AppDelegate.requestNotificationPermission` runs on cold
launch. The share will silently stage either way (R5 design — the
extension never blocks on permission); the items just won't surface
a toast until the user permits notifications.

If step 3 fails (queued notification persists, no "Saved to Shelf" follow-up):
check the lifecycle hook in `lib/app/app.dart` is running on
`AppLifecycleState.resumed` and `ShelfIosBridge.drainAppGroupContainer`
is invoked. Logs from `AppDelegate.drainAppGroupContainerSync` should
report the txn count under `os_log`'s `land.fx.files.ShelfShare`
subsystem.
