# Backitup repository instructions

Backitup is a SwiftUI macOS app for browsing, exporting, backing up, and optionally deleting photos and videos from a USB-connected iPhone. The source of truth for current capabilities and limits is [README.md](README.md).

## Project map

- `Sources/Backitup/DeviceLibrary.swift`: ImageCaptureCore connection, live catalog, thumbnails, and device deletion.
- `Sources/Backitup/CatalogCache.swift`: local catalog and thumbnail cache.
- `Sources/Backitup/BackupService.swift`: export, manifest, checksums, and backup verification.
- `Sources/Backitup/ContentView.swift` and `ExportSheet.swift`: gallery, selection, backup and delete flows, and export options.
- `Tests/BackitupTests/`: fixture-based tests for gallery behavior, dates, cache, and backup safety.

## Build and verify

- Requires macOS 14 or later and Xcode. Run `./scripts/build-app.sh` from the repository root; it creates `dist/Backitup.app`.
- Run tests with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" xcrun swift test --disable-sandbox`.
- Use focused tests for behavior changes. A successful build or fixture test does not establish that an iPhone transfer or deletion works; report live-device results separately.

## Product behavior to preserve

- The default gallery groups items by date. Keep date order, date filtering, and Shift range selection working with both cached and live catalogs.
- Browsing should remain available from cached metadata and thumbnails after the iPhone locks or disconnects. Transfers and deletion still require an accessible device.
- Treat ImageCaptureCore's catalog as the files macOS currently exposes, not proof of everything in the iPhone Photos library. Wait for a complete device catalog before replacing the displayed list. Preserve the previous larger catalog when a new scan is smaller so missing items can be investigated.
- Preserve the relationship between edited renders, originals, Live Photo videos, burst frames, and other related files when exporting or deciding whether deletion is safe.

## Data safety

- A manifest entry alone is not proof of backup. Verify the local file size and SHA-256 digest of the primary file and every recorded related file before marking an item verified, and recheck immediately before device deletion.
- Converted copies and exports missing related originals are not deletion-safe. Keep deletion limited to the explicitly chosen, verified items; if some selected items fail verification, leave those on the iPhone.
- Do not clear or overwrite a user's backup folder, `.backitup-manifest.json`, or saved catalog as a troubleshooting shortcut. Investigate and preserve evidence first.
- Do not use real iPhone deletion as an automated test. When a task explicitly requests device deletion, carry out only the requested verified subset and report the device's actual result, including partial failures.
