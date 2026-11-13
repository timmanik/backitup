# Backitup

A native macOS photo browser and local backup app for a USB-connected iPhone. Built with SwiftUI and Apple's ImageCaptureCore.

## Build and open

Requires macOS 14 or later and Xcode with the macOS SDK. From this directory:

```sh
./scripts/build-app.sh
open dist/Backitup.app
```

Connect and unlock your iPhone, tap **Trust** if prompted, and grant the macOS photo/camera permission. The app reads the media catalog through Image Capture. It does not need an account or network access.

After the first successful catalog, Backitup saves photo metadata and thumbnails in the Mac's Application Support folder. You can continue browsing these cached photos when the iPhone locks or disconnects. Keep the phone unlocked for exports and deletion; Backitup retries a failed initial connection automatically.

Thumbnail caching continues in the background. Items that have not been cached yet may show placeholders while the iPhone is unavailable; opening the gallery during a live connection gives visible items priority.

The gallery groups an edited `FullSizeRender` with its matching `IMG_` original into one tile. Storage totals still include both source files. If you export the grouped item with edited originals enabled, Backitup saves both files.

## Workflow

1. Select items in **All Photos**, optionally filtering by media type or filename.
2. Choose **Export selected**. Select the media types, related files, folder structure, names, and conversion options.
3. Choose a backup folder. Each successfully exported item is added to `.backitup-manifest.json` with its local SHA-256 digest.
4. Use **Check backup** to verify selected items. **Delete** is enabled only when every selected item verifies. Backitup repeats verification immediately before requesting deletion from the iPhone.

For deletion, Backitup also checks every related file it exported. A converted photo/video or an export missing a sidecar is shown as **Copies only** and cannot be deleted from the iPhone through the app. Export the original with related files to make it eligible.

The storage tab reports the file sizes of accessible photos and videos, broken down by media type. Apple's public Image Capture API does not expose the iPhone's total capacity or Apps/System/free-space categories. iCloud-only assets and locked Hidden album contents may not appear. Deletion is disabled when iCloud Photos is enabled, as Apple does not permit this through Image Capture.

## Current limits

- Classification comes from Image Capture metadata. Portrait and edited-original distinctions are not always exposed, so related-file options download available sidecars together. Location folders use device GPS text where present; reverse geocoding is not implemented.
- Video conversion uses the macOS MP4 export preset and may change codec or dimensions. Keep conversion off for bit-identical originals.
- The manifest verifies backups made by Backitup in the selected folder; it does not search arbitrary folders or the Mac Photos library.
- Deletion and high-volume exports still need testing with a physical iPhone and the user's iOS settings. The app has no automatic deletion after export.
