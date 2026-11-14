import AVFoundation
import CryptoKit
import Foundation
import ImageCaptureCore
import ImageIO
import UniformTypeIdentifiers

final class BackupService {
    static let manifestName = ".backitup-manifest.json"

    struct ExportResult {
        let exported: Int
        let skipped: Int
        let failures: [String]
        let states: [String: BackupState]
    }

    struct ItemExportResult {
        let record: BackupRecord
        let warning: String?
    }

    func loadManifest(at root: URL) -> BackupManifest {
        let url = root.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else { return BackupManifest() }
        return manifest
    }

    func verify(_ asset: PhotoAsset, at root: URL, manifest: BackupManifest) -> BackupState {
        guard let record = manifest.records[asset.sourceKey] else { return .missing }
        let files = [BackupFileRecord(relativePath: record.relativePath, sha256: record.sha256, bytes: record.bytes)] + record.relatedFiles
        for file in files {
            let url = root.appendingPathComponent(file.relativePath).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  FileManager.default.fileExists(atPath: url.path),
                  let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(bytes) == file.bytes,
                  let digest = try? sha256(url), digest == file.sha256 else { return .changed }
        }
        return record.deletionSafe ? .verified : .partial
    }

    func export(
        assets: [PhotoAsset], library: DeviceLibrary, root: URL, options: ExportOptions,
        progress: @escaping (Int, Int, String) -> Void
    ) async throws -> ExportResult {
        let granted = root.startAccessingSecurityScopedResource()
        defer { if granted { root.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent(Self.manifestName)
        var manifest: BackupManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        } else {
            manifest = BackupManifest()
        }
        var exported = 0
        var skipped = 0
        var failures: [String] = []
        var states: [String: BackupState] = [:]
        let selected = assets.filter { options.kinds.contains($0.kind) }
        let targetIDs = options.includeEditedOriginals
            ? DeviceLibrary.deletionTargetIDs(for: Set(selected.map(\.id)), assets: library.assets, galleryAssets: library.galleryAssets)
            : Set(selected.map(\.id))
        let selectedIDs = Set(selected.map(\.id))
        let included = selected + library.assets.filter { targetIDs.contains($0.id) && !selectedIDs.contains($0.id) }
        for (index, asset) in included.enumerated() {
            progress(index, included.count, "Backing up \(asset.name)…")
            guard let file = library.file(for: asset.id) else {
                failures.append("\(asset.name): no longer available from iPhone")
                states[asset.id] = verify(asset, at: root, manifest: manifest)
                continue
            }
            if verify(asset, at: root, manifest: manifest) == .verified {
                skipped += 1
                states[asset.id] = .verified
                continue
            }
            let priorRecord = manifest.records[asset.sourceKey]
            do {
                let result = try await exportOne(asset: asset, file: file, library: library, root: root, options: options,
                                                 allowPartial: priorRecord == nil)
                manifest.records[asset.sourceKey] = result.record
                try save(manifest, at: root)
                exported += 1
                states[asset.id] = verify(asset, at: root, manifest: manifest)
                if let warning = result.warning { failures.append("\(asset.name): \(warning)") }
            } catch {
                failures.append("\(asset.name): \(error.localizedDescription)")
                manifest.records[asset.sourceKey] = priorRecord
                states[asset.id] = verify(asset, at: root, manifest: manifest)
            }
        }
        progress(included.count, included.count,
                 "Backup finished: \(exported) new, \(skipped) already verified, \(failures.count) failed.")
        return ExportResult(exported: exported, skipped: skipped, failures: failures, states: states)
    }

    private func exportOne(asset: PhotoAsset, file: ICCameraFile, library: DeviceLibrary,
                           root: URL, options: ExportOptions, allowPartial: Bool) async throws -> ItemExportResult {
        let folder = destinationFolder(for: asset, location: file.gpsString, root: root, options: options)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Backitup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let safeName = sanitized(asset.name)
        let wantsSidecars = options.includeLiveVideos || options.includePortraitOriginals || options.includeEditedOriginals || options.includeBurstFrames
        let downloaded: String
        do {
            downloaded = try await download(file, to: staging, name: safeName, sidecars: wantsSidecars)
        } catch {
            let originalError = error
            if wantsSidecars && (error as NSError).domain == "com.apple.ImageCaptureCore" && (error as NSError).code == -9934 {
                let probe = staging.appendingPathComponent("primary-probe", isDirectory: true)
                try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
                do {
                    let name = try await download(file, to: probe, name: safeName, sidecars: false)
                    let url = probe.appendingPathComponent(name)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard let size, size > 0, file.fileSize == 0 || Int64(size) == Int64(file.fileSize) else {
                        throw AppError.message("The retry returned a missing or incomplete file.")
                    }
                    throw AppError.message("The photo downloaded without related files, but the request including related files failed (Image Capture error -9934). No complete backup was recorded.")
                } catch let probeError as AppError {
                    throw probeError
                } catch {
                    throw AppError.message("Image Capture failed to download the photo both with and without related files: \(originalError.localizedDescription); retry: \(error.localizedDescription)")
                }
            }
            throw AppError.message("Could not download the primary file: \(originalError.localizedDescription)")
        }
        let source = staging.appendingPathComponent(downloaded)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AppError.message("The iPhone reported a completed download, but \(asset.name) was not found in the staging folder.")
        }
        let groupedRelated = library.relatedFiles(for: asset)
        let declaredSidecars = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
        let pairedRaw = file.pairedRawImage.map { [$0] } ?? []
        var relatedFiles: [ICCameraFile] = []
        var seenFiles = Set([ObjectIdentifier(file)])
        for relatedFile in groupedRelated + declaredSidecars + pairedRaw {
            if seenFiles.insert(ObjectIdentifier(relatedFile)).inserted { relatedFiles.append(relatedFile) }
        }
        do {
        if wantsSidecars {
            var relatedNames = Set<String>()
            for relatedFile in relatedFiles {
                let relatedName = sanitized(relatedFile.originalFilename ?? relatedFile.name ?? "Related original")
                guard relatedNames.insert(relatedName.lowercased()).inserted else {
                    throw AppError.message("More than one related file is named \(relatedName).")
                }
                let relatedURL = staging.appendingPathComponent(relatedName)
                guard relatedURL != source else { throw AppError.message("Related file has the same name as the primary file: \(relatedName).") }
                // Download separately: Image Capture can return before automatically requested sidecars are complete.
                let separate = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: separate, withIntermediateDirectories: true)
                let actualName: String
                do { actualName = try await download(relatedFile, to: separate, name: relatedName, sidecars: false) }
                catch { throw AppError.message("Could not download related file \(relatedName): \(error.localizedDescription)") }
                let actualURL = separate.appendingPathComponent(actualName)
                let actualSize = try actualURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard Self.relatedSizeIsComplete(expected: Int64(relatedFile.fileSize), actual: actualSize.map(Int64.init)) else {
                    throw AppError.message("Could not confirm \(relatedName): iPhone reported \(relatedFile.fileSize) bytes; downloaded \(actualSize.map(String.init) ?? "no file") bytes.")
                }
                if FileManager.default.fileExists(atPath: relatedURL.path) { try FileManager.default.removeItem(at: relatedURL) }
                try FileManager.default.moveItem(at: actualURL, to: relatedURL)
            }
        }
        } catch {
            guard allowPartial else { throw error }
            let record = try savePartialPrimary(source, asset: asset, folder: folder, root: root)
            return ItemExportResult(record: record, warning: "Primary file saved as a partial backup; \(error.localizedDescription) The item cannot be deleted yet.")
        }
        let finalName = options.originalFilenames ? safeName : generatedName(for: asset)
        var target = uniqueURL(in: folder, name: finalName)
        var converted = false
        if options.convertHEIC && ["heic", "heif"].contains(target.pathExtension.lowercased()) {
            target = uniqueURL(in: folder, name: (target.deletingPathExtension().lastPathComponent) + ".jpg")
            try convertHEIC(source, to: target, quality: options.jpegQuality)
            converted = true
        } else if options.convertHEVC && ["mov", "mp4"].contains(target.pathExtension.lowercased()) {
            let mp4 = uniqueURL(in: folder, name: target.deletingPathExtension().lastPathComponent + ".mp4")
            try await convertVideo(source, to: mp4)
            target = mp4
            converted = true
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
        // Keep any related Live Photo/portrait files beside their primary item.
        var related: [BackupFileRecord] = []
        if let staged = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            for sidecar in staged where sidecar != source && sidecar.hasDirectoryPath == false {
                let sidecarTarget = uniqueURL(in: folder, name: sanitized(sidecar.lastPathComponent))
                try FileManager.default.moveItem(at: sidecar, to: sidecarTarget)
                related.append(try fileRecord(for: sidecarTarget, root: root))
            }
        }
        let primary = try fileRecord(for: target, root: root)
        let expectedSidecars = relatedFiles.count
        let record = BackupRecord(sourceKey: asset.sourceKey, relativePath: primary.relativePath,
                            sha256: primary.sha256, bytes: primary.bytes, backedUpAt: Date(),
                            relatedFiles: related, deletionSafe: !converted && related.count >= expectedSidecars)
        return ItemExportResult(record: record, warning: nil)
    }

    func savePartialPrimary(_ source: URL, asset: PhotoAsset, folder: URL, root: URL) throws -> BackupRecord {
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        guard asset.bytes > 0, let size, size.int64Value == asset.bytes else {
            throw AppError.message("The downloaded primary file does not match the iPhone's reported size.")
        }
        let target = uniqueURL(in: folder, name: sanitized(asset.name))
        try FileManager.default.copyItem(at: source, to: target)
        let primary = try fileRecord(for: target, root: root)
        return BackupRecord(sourceKey: asset.sourceKey, relativePath: primary.relativePath, sha256: primary.sha256,
                            bytes: primary.bytes, backedUpAt: Date(), relatedFiles: [], deletionSafe: false)
    }

    static func relatedSizeIsComplete(expected: Int64, actual: Int64?) -> Bool {
        guard let actual, actual > 0 else { return false }
        return expected == 0 || expected == actual
    }

    private func save(_ manifest: BackupManifest, at root: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    private func fileRecord(for url: URL, root: URL) throws -> BackupFileRecord {
        BackupFileRecord(relativePath: String(url.path.dropFirst(root.path.count + 1)),
                         sha256: try sha256(url),
                         bytes: Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0))
    }

    private func download(_ file: ICCameraFile, to folder: URL, name: String, sidecars: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = file.requestDownload(options: [
                .downloadsDirectoryURL: folder,
                .saveAsFilename: name,
                .sidecarFiles: sidecars,
                .overwrite: false
            ]) { filename, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: filename ?? name) }
            }
        }
    }

    func destinationFolder(for asset: PhotoAsset, location: String?, root: URL, options: ExportOptions) -> URL {
        var folder = root
        if options.moments {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let date = asset.date == .distantPast ? "Unknown date" : formatter.string(from: asset.date)
            let year = asset.date == .distantPast ? "Unknown year" : String(date.prefix(4))
            let location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if options.momentFolderName != .dateOnly, let location, !location.isEmpty {
                let safeLocation = sanitized(location)
                label = options.momentFolderName == .locationDate ? "\(safeLocation) - \(date)" : "\(date) - \(safeLocation)"
            } else {
                label = date
            }
            folder.appendPathComponent(year, isDirectory: true)
            folder.appendPathComponent(label, isDirectory: true)
        }
        if options.mediaFolders { folder.appendPathComponent(asset.kind.rawValue, isDirectory: true) }
        return folder
    }

    private func generatedName(for asset: PhotoAsset) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = asset.date == .distantPast ? "undated" : formatter.string(from: asset.date)
        return "\(stamp)-\(UUID().uuidString.prefix(8)).\((asset.name as NSString).pathExtension)"
    }

    private func sanitized(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(clean.prefix(120)).isEmpty ? "Untitled" : String(clean.prefix(120))
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var index = 2
        while true {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let url = folder.appendingPathComponent("\(base) \(index)\(suffix)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func convertHEIC(_ source: URL, to target: URL, quality: Double) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppError.message("Could not decode HEIC image \(source.lastPathComponent).")
        }
        let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Could not save JPEG for \(source.lastPathComponent).") }
    }

    private func convertVideo(_ source: URL, to target: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError.message("This video cannot be converted to MP4.")
        }
        session.outputURL = target
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? AppError.message("Video conversion failed.")
        }
    }
}
