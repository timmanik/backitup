import CryptoKit
import Foundation

struct CachedCatalog: Codable {
    let deviceID: String
    let deviceName: String
    let savedAt: Date
    let assets: [PhotoAsset]
}

final class CatalogCache {
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backitup", isDirectory: true)
    }

    func loadLast() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("catalog.json")) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    func save(_ catalog: CachedCatalog) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogURL = root.appendingPathComponent("catalog.json")
        if let oldData = try? Data(contentsOf: catalogURL),
           let old = try? JSONDecoder().decode(CachedCatalog.self, from: oldData),
           old.assets.count > catalog.assets.count {
            let previousURL = root.appendingPathComponent("catalog-previous.json")
            let previousCount = (try? Data(contentsOf: previousURL))
                .flatMap { try? JSONDecoder().decode(CachedCatalog.self, from: $0).assets.count } ?? 0
            if old.assets.count > previousCount {
                try oldData.write(to: previousURL, options: .atomic)
            }
        }
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: catalogURL, options: .atomic)
    }

    func thumbnail(for asset: PhotoAsset) -> Data? {
        try? Data(contentsOf: thumbnailURL(for: asset))
    }

    func hasThumbnail(for asset: PhotoAsset) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(for: asset).path)
    }

    func saveThumbnail(_ data: Data, for asset: PhotoAsset) throws {
        let url = thumbnailURL(for: asset)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func thumbnailURL(for asset: PhotoAsset) -> URL {
        let digest = SHA256.hash(data: Data(asset.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent(digest + ".image")
    }
}
