import AppKit
import Combine
import ImageCaptureCore

final class DeviceLibrary: NSObject, ObservableObject {
    @Published private(set) var deviceName: String?
    @Published private(set) var cachedDeviceName: String?
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var galleryAssets: [PhotoAsset] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isICloudPhotosEnabled = false
    @Published private(set) var status = "Connect and unlock your iPhone to browse its photos."
    @Published private(set) var backupStates: [String: BackupState] = [:]
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var busy = false
    @Published private(set) var deleting = false
    @Published private(set) var deletionFraction: Double?

    private let browser = ICDeviceBrowser()
    private let cache = CatalogCache()
    private let cacheSaveQueue = DispatchQueue(label: "Backitup.catalog.save", qos: .utility)
    private var camera: ICCameraDevice?
    private var files: [String: ICCameraFile] = [:]
    private var requestedThumbnails = Set<String>()
    private var visibleThumbnailIDs = Set<String>()
    private var lastDeviceID: String?
    private var refreshing = false
    private var reloadingCatalog = false
    private var catalogReady = false
    private var deviceReportedReady = false
    private var catalogUpdateWorkItem: DispatchWorkItem?
    private var openingSession = false
    private var sessionFailed = false
    private var lastSessionAttempt = Date.distantPast
    private var lastCatalogActivity = Date()
    private var lastCatalogPercent = 0
    private var retryTimer: Timer?
    private var lastDiscoveryAttempt = Date()
    private var prefetchAssets: [PhotoAsset] = []
    private var prefetchCursor = 0
    private var prefetchInFlight = 0
    private var prefetchPaused = false
    private var prefetchFailures: [PhotoAsset] = []
    private var prefetchGeneration = 0
    private var deletionProgressTimer: Timer?

    override init() {
        super.init()
        if let saved = cache.loadLast() {
            assets = saved.assets
            galleryAssets = Self.groupedGallery(saved.assets)
            cachedDeviceName = saved.deviceName
            lastDeviceID = saved.deviceID
            status = "Showing \(saved.assets.count.formatted()) cached items from \(saved.deviceName). Connect and unlock to export."
        }
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        browser.start()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.retryIfNeeded()
        }
    }

    deinit { retryTimer?.invalidate(); deletionProgressTimer?.invalidate(); browser.stop() }

    func refresh() {
        guard let camera else { return }
        catalogUpdateWorkItem?.cancel()
        catalogUpdateWorkItem = nil
        deviceReportedReady = false
        isLoading = true
        status = assets.isEmpty ? "Refreshing photo catalog…" : "Refreshing photo catalog; saved thumbnails remain visible…"
        catalogReady = false
        openingSession = false
        sessionFailed = false
        refreshing = true
        reloadingCatalog = true
        files = [:]
        requestedThumbnails = []
        backupStates = [:]
        prefetchAssets = []
        prefetchInFlight = 0
        prefetchPaused = false
        prefetchFailures = []
        prefetchGeneration += 1
        if camera.hasOpenSession { camera.requestCloseSession() }
        else { refreshing = false; openSession(camera) }
    }

    var canTransfer: Bool {
        camera?.hasOpenSession == true && camera?.isAccessRestrictedAppleDevice == false && catalogReady
    }

    private func openSession(_ device: ICCameraDevice) {
        guard !openingSession else { return }
        openingSession = true
        sessionFailed = false
        lastSessionAttempt = Date()
        lastCatalogActivity = Date()
        lastCatalogPercent = 0
        isLoading = true
        status = "Connecting to \(device.name ?? "iPhone")…"
        device.requestOpenSession()
    }

    private func retryIfNeeded() {
        guard let camera else {
            if let found = browser.devices?.compactMap({ $0 as? ICCameraDevice }).first {
                deviceBrowser(browser, didAdd: found, moreComing: false)
            } else if Date().timeIntervalSince(lastDiscoveryAttempt) > 12 {
                lastDiscoveryAttempt = Date()
                browser.stop()
                browser.start()
            }
            return
        }
        guard !catalogReady, !refreshing else { return }
        if camera.hasOpenSession {
            let percent = camera.contentCatalogPercentCompleted
            if percent > lastCatalogPercent {
                lastCatalogPercent = percent
                lastCatalogActivity = Date()
            }
        }
        // A failed session can remain stuck on the unlock error even after the phone is unlocked.
        // Retry automatically while the device is present, without asking the user to reconnect it.
        if openingSession && Date().timeIntervalSince(lastSessionAttempt) < 12 { return }
        if !sessionFailed && !openingSession {
            guard camera.hasOpenSession,
                  Date().timeIntervalSince(lastCatalogActivity) > 120 else { return }
            refreshing = true
            camera.requestCloseSession()
            return
        }
        openingSession = false
        if camera.hasOpenSession {
            refreshing = true
            camera.requestCloseSession()
        } else {
            openSession(camera)
        }
    }

    func file(for id: String) -> ICCameraFile? { files[id] }

    func relatedFiles(for asset: PhotoAsset) -> [ICCameraFile] {
        guard let groupID = asset.groupID else { return [] }
        return assets.compactMap { other -> ICCameraFile? in
            guard other.id != asset.id, other.groupID == groupID else { return nil }
            return files[other.id]
        }
    }

    func requestThumbnail(for id: String) {
        guard thumbnails[id] == nil, !requestedThumbnails.contains(id),
              let asset = assets.first(where: { $0.id == id }) else { return }
        visibleThumbnailIDs.insert(id)
        if let data = cache.thumbnail(for: asset), let image = NSImage(data: data) {
            thumbnails[id] = image
            return
        }
        guard camera?.hasOpenSession == true, let file = files[id] else { return }
        requestedThumbnails.insert(id)
        file.requestThumbnailData(options: nil) { [weak self] data, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestedThumbnails.remove(id)
                guard let data else { return }
                if self.visibleThumbnailIDs.contains(id), let image = NSImage(data: data) { self.thumbnails[id] = image }
                try? self.cache.saveThumbnail(data, for: asset)
            }
        }
    }

    func releaseThumbnail(for id: String) {
        visibleThumbnailIDs.remove(id)
        thumbnails.removeValue(forKey: id)
    }

    func canDelete(_ ids: Set<String>) -> Bool {
        guard !ids.isEmpty, canTransfer, camera?.isLocked == false else { return false }
        let targetIDs = Self.deletionTargetIDs(for: ids, assets: assets, galleryAssets: galleryAssets)
        return ids.isSubset(of: targetIDs) &&
            Self.allTargetsVerified(targetIDs, states: backupStates) &&
            targetIDs.allSatisfy { files[$0] != nil }
    }

    static func allTargetsVerified(_ ids: Set<String>, states: [String: BackupState]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { states[$0] == .verified }
    }

    static func verifiedGalleryIDs(_ ids: Set<String>, assets: [PhotoAsset], galleryAssets: [PhotoAsset],
                                   states: [String: BackupState]) -> Set<String> {
        let displayed = Set(galleryAssets.map(\.id))
        var selectedGroups: [String: String] = [:]
        var hiddenByGroup: [String: [String]] = [:]
        for asset in assets {
            guard let group = asset.groupID else { continue }
            if ids.contains(asset.id) { selectedGroups[asset.id] = group }
            if !displayed.contains(asset.id) { hiddenByGroup[group, default: []].append(asset.id) }
        }
        let existingIDs = Set(assets.map(\.id))
        return Set(ids.filter { id in
            guard existingIDs.contains(id), states[id] == .verified else { return false }
            guard let group = selectedGroups[id] else { return true }
            return (hiddenByGroup[group] ?? []).allSatisfy { states[$0] == .verified }
        })
    }

    func deleteVerified(_ ids: Set<String>, completion: @escaping (Result<Int, Error>) -> Void) {
        guard canDelete(ids), let camera else {
            completion(.failure(AppError.message("Every selected item must have a verified local backup, and the device must allow deletion.")))
            return
        }
        let targetIDs = Self.deletionTargetIDs(for: ids, assets: assets, galleryAssets: galleryAssets)
        let targets: [ICCameraItem] = targetIDs.compactMap { files[$0] }
        busy = true
        deleting = true
        deletionFraction = nil
        total = 0
        completed = 0
        status = "Deleting \(targets.count) verified items from iPhone…"
        var failed = 0
        let failureLock = NSLock()
        let progress = camera.requestDeleteFiles(targets, deleteFailed: { failures in
            failureLock.lock()
            failed += failures.count
            failureLock.unlock()
        }, completion: { [weak self] results, error in
            failureLock.lock()
            let reportedFailures = failed
            failureLock.unlock()
            let successful = results[.successful]?.count ?? 0
            let resultFailures = results[.failed]?.count ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.deletionProgressTimer?.invalidate()
                self.deletionProgressTimer = nil
                self.deletionFraction = nil
                self.deleting = false
                self.busy = false
                self.total = 0
                self.completed = 0
                self.refresh()
                if let error { completion(.failure(error)) }
                else if reportedFailures > 0 || resultFailures > 0 || successful != targets.count {
                    completion(.failure(AppError.message(
                        "Image Capture reported \(successful) of \(targets.count) source files deleted. The iPhone catalog is being refreshed; check the remaining items before trying again."
                    )))
                } else {
                    completion(.success(successful))
                }
            }
        })
        if let progress {
            deletionProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak progress] timer in
                guard let self, self.deleting, let progress else { timer.invalidate(); return }
                let fraction = progress.fractionCompleted
                self.deletionFraction = fraction > 0 && fraction < 1 ? fraction : nil
            }
        }
    }

    func setBackupState(_ state: BackupState, for id: String) { backupStates[id] = state }
    func setBackupStates(_ states: [String: BackupState]) {
        var updated = backupStates
        updated.merge(states) { _, new in new }
        backupStates = updated
    }
    func startProgress(total: Int, message: String) {
        busy = true
        self.total = total
        completed = 0
        status = message
    }
    func advanceProgress(_ message: String) {
        completed += 1
        status = message
    }
    func updateProgress(_ done: Int, total: Int, message: String) {
        completed = done
        self.total = total
        status = message
    }
    func stopProgress(_ message: String) {
        busy = false
        status = message
    }

    private func ingest(_ incoming: [ICCameraItem]) {
        if reloadingCatalog {
            assets = []
            files = [:]
            reloadingCatalog = false
        }
        var additions: [PhotoAsset] = []
        for case let file as ICCameraFile in incoming {
            let id = "\(file.ptpObjectHandle)-\(file.name ?? "")"
            guard files[id] == nil else { continue }
            let name = file.originalFilename ?? file.name ?? "Untitled"
            let ext = (name as NSString).pathExtension.lowercased()
            let video = ["mov", "mp4", "m4v", "avi"].contains(ext)
            let kind: MediaKind
            if file.highFramerate && video { kind = .slowMotion }
            else if video { kind = .video }
            else if file.burstUUID != nil { kind = .burst }
            else if name.lowercased().hasPrefix("screenshot") { kind = .screenshot }
            else if file.width > 0 && file.height > 0 && max(file.width, file.height) > 2 * min(file.width, file.height) { kind = .panorama }
            else { kind = .photo }
            files[id] = file
            additions.append(PhotoAsset(
                id: id, deviceID: camera?.uuidString ?? "unknown-device", name: name, date: file.exifCreationDate ?? file.fileCreationDate ?? .distantPast,
                bytes: Int64(file.fileSize), kind: kind, groupID: file.groupUUID ?? file.relatedUUID,
                width: file.width, height: file.height
            ))
        }
        guard !additions.isEmpty else { return }
        lastCatalogActivity = Date()
        assets.append(contentsOf: additions)
        if deviceReportedReady {
            catalogReady = false
            isLoading = true
            status = "Finishing iPhone photo catalog (\(assets.count.formatted()) source files)…"
            scheduleCatalogUpdate()
        }
    }

    private func classifyLivePhotos() {
        let pairedVideoIDs = Set(files.values.compactMap { file -> String? in
            let name = file.originalFilename ?? file.name ?? ""
            guard ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return file.relatedUUID
        })
        guard !pairedVideoIDs.isEmpty else { return }
        var classified = assets
        for index in classified.indices where classified[index].kind == .photo {
            guard let uuid = files[classified[index].id]?.relatedUUID, pairedVideoIDs.contains(uuid) else { continue }
            classified[index].kind = .live
        }
        assets = classified
    }

    static func groupedGallery(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        let groups = Dictionary(grouping: assets.compactMap { asset -> (String, PhotoAsset)? in
            guard let groupID = asset.groupID else { return nil }
            return (groupID, asset)
        }, by: { $0.0 })
        let hidden = Set(groups.values.compactMap { members -> String? in
            guard members.count == 2,
                  members.contains(where: { $0.1.name.lowercased().hasPrefix("fullsizerender") }) else { return nil }
            return members.first(where: { $0.1.name.uppercased().hasPrefix("IMG_") })?.1.id
        })
        return assets.filter { !hidden.contains($0.id) }
    }

    static func deletionTargetIDs(for selectedIDs: Set<String>, assets: [PhotoAsset],
                                  galleryAssets: [PhotoAsset]) -> Set<String> {
        let displayedIDs = Set(galleryAssets.map(\.id))
        let selectedGroupIDs = Set(assets.compactMap { asset in
            selectedIDs.contains(asset.id) ? asset.groupID : nil
        })
        return Set(assets.compactMap { asset in
            if selectedIDs.contains(asset.id) { return asset.id }
            if !displayedIDs.contains(asset.id), let groupID = asset.groupID,
               selectedGroupIDs.contains(groupID) { return asset.id }
            return nil
        })
    }

    private func persistCatalog() {
        guard let deviceID = camera?.uuidString, let name = deviceName else { return }
        let snapshot = CachedCatalog(deviceID: deviceID, deviceName: name, savedAt: Date(), assets: assets)
        cacheSaveQueue.async { [cache] in
            try? cache.save(snapshot)
        }
    }

    private func scheduleCatalogUpdate() {
        catalogUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishCatalogUpdate() }
        catalogUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func finishCatalogUpdate() {
        guard deviceReportedReady else { return }
        guard let camera, camera.contentCatalogPercentCompleted >= 100 else {
            scheduleCatalogUpdate()
            return
        }
        // The ready callback can precede queued didAdd callbacks. The device's own
        // mediaFiles array is the authoritative complete list at this point.
        if let mediaFiles = camera.mediaFiles, !mediaFiles.isEmpty { ingest(mediaFiles) }
        // A ready callback can arrive before queued didAdd callbacks. Keep the saved
        // gallery until at least one live item has arrived.
        guard !assets.isEmpty || galleryAssets.isEmpty else { return }
        assets.sort { $0.date > $1.date }
        classifyLivePhotos()
        galleryAssets = Self.groupedGallery(assets)
        catalogReady = camera.hasOpenSession && !camera.isAccessRestrictedAppleDevice
        openingSession = false
        sessionFailed = !catalogReady
        isLoading = false
        isICloudPhotosEnabled = camera.iCloudPhotosEnabled
        status = catalogReady
            ? "\(galleryAssets.count.formatted()) gallery items ready (\(assets.count.formatted()) source files)"
            : "Showing \(galleryAssets.count.formatted()) cached photos; unlock iPhone to export."
        persistCatalog()
        if catalogReady { startThumbnailPrefetch() }
    }

    private func startThumbnailPrefetch() {
        prefetchAssets = galleryAssets
        prefetchCursor = 0
        prefetchInFlight = 0
        prefetchPaused = false
        prefetchFailures = []
        prefetchGeneration += 1
        pumpThumbnailPrefetch()
    }

    private func pumpThumbnailPrefetch() {
        guard !prefetchPaused, catalogReady, camera?.hasOpenSession == true else { return }
        while prefetchInFlight < 4 && prefetchCursor < prefetchAssets.count {
            let asset = prefetchAssets[prefetchCursor]
            prefetchCursor += 1
            if cache.hasThumbnail(for: asset) { continue }
            guard let file = files[asset.id] else { continue }
            prefetchInFlight += 1
            let generation = prefetchGeneration
            file.requestThumbnailData(options: nil) { [weak self] data, _ in
                if let data { try? self?.cache.saveThumbnail(data, for: asset) }
                DispatchQueue.main.async {
                    guard let self, self.prefetchGeneration == generation else { return }
                    self.prefetchInFlight = max(0, self.prefetchInFlight - 1)
                    if let data, self.visibleThumbnailIDs.contains(asset.id),
                       let image = NSImage(data: data) { self.thumbnails[asset.id] = image }
                    if data == nil {
                        self.prefetchPaused = true
                        self.prefetchFailures.append(asset)
                    }
                    self.pumpThumbnailPrefetch()
                }
            }
        }
    }

    private func resumeThumbnailPrefetch() {
        if !prefetchFailures.isEmpty {
            prefetchAssets.insert(contentsOf: prefetchFailures, at: min(prefetchCursor, prefetchAssets.count))
            prefetchFailures = []
        }
        prefetchPaused = false
        pumpThumbnailPrefetch()
    }
}

extension DeviceLibrary: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            guard self.camera == nil else { return }
            if self.lastDeviceID != nil && self.lastDeviceID != camera.uuidString {
                self.assets = []
                self.galleryAssets = []
                self.thumbnails = [:]
                self.cachedDeviceName = nil
            }
            self.camera = camera
            self.lastDeviceID = camera.uuidString
            self.deviceName = camera.name ?? "iPhone"
            self.cachedDeviceName = self.deviceName
            self.isICloudPhotosEnabled = camera.iCloudPhotosEnabled
            self.isLoading = true
            self.catalogReady = false
            self.deviceReportedReady = false
            self.reloadingCatalog = true
            camera.delegate = self
            self.openSession(camera)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        DispatchQueue.main.async {
            guard self.camera?.uuidString == device.uuidString else { return }
            self.camera = nil
            self.deviceName = nil
            self.files = [:]
            self.requestedThumbnails = []
            self.visibleThumbnailIDs = []
            self.backupStates = [:]
            self.isLoading = false
            self.reloadingCatalog = false
            self.catalogReady = false
            self.deviceReportedReady = false
            self.catalogUpdateWorkItem?.cancel()
            self.catalogUpdateWorkItem = nil
            self.openingSession = false
            self.sessionFailed = false
            self.refreshing = false
            self.prefetchAssets = []
            self.prefetchInFlight = 0
            self.prefetchPaused = false
            self.prefetchFailures = []
            self.prefetchGeneration += 1
            self.status = "iPhone disconnected. Showing \(self.assets.count.formatted()) cached items. Reconnect to export."
        }
    }
}

extension DeviceLibrary: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        openingSession = false
        if let error {
            sessionFailed = true
            status = assets.isEmpty
                ? "Waiting for iPhone access: \(error.localizedDescription). Retrying automatically…"
                : "Showing cached photos. \(error.localizedDescription) Retrying automatically…"
            isLoading = false
        } else {
            sessionFailed = false
            isLoading = true
            status = "Reading photos from \(device.name ?? "iPhone")…"
        }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if refreshing {
            refreshing = false
            if let camera { openSession(camera) }
        }
    }
    func didRemove(_ device: ICDevice) { }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        DispatchQueue.main.async {
            guard self.camera === camera else { return }
            self.ingest(items)
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        // Image Capture can report removals when an iPhone locks. Keep the local catalog
        // until the next complete refresh; this also avoids losing the gallery on idle lock.
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) { }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) { }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async {
            guard self.camera === device else { return }
            if let mediaFiles = device.mediaFiles, !mediaFiles.isEmpty {
                self.ingest(mediaFiles)
            } else if self.reloadingCatalog {
                self.assets = []
                self.files = [:]
                self.reloadingCatalog = false
            }
            self.deviceReportedReady = true
            self.lastCatalogActivity = Date()
            self.isLoading = true
            self.status = "Finishing iPhone photo catalog (\(self.assets.count.formatted()) source files)…"
            self.scheduleCatalogUpdate()
        }
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        if catalogReady {
            if let camera, !camera.hasOpenSession { refresh() }
            else { resumeThumbnailPrefetch() }
        } else if let camera {
            if camera.hasOpenSession {
                // The iPhone may still be delivering its catalog. Closing here can
                // interrupt the older batches that follow the ready callback.
                sessionFailed = false
                lastCatalogActivity = Date()
                isLoading = true
                status = "Reading photos from \(device.name ?? "iPhone")…"
            } else {
                openingSession = false
                openSession(camera)
            }
        }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        sessionFailed = true
        isLoading = false
        status = assets.isEmpty
            ? "Unlock your iPhone and tap Trust if prompted. Retrying automatically…"
            : "iPhone locked. Showing cached photos; unlock again only to export."
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
