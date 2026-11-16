import BackLogCore
import ImageIO
import SwiftUI

/// An item's picture: the saved file, decoded off the main thread at the size it's shown and
/// kept in memory, else the remote image, else the kind's symbol.
struct Thumbnail: View {
    let item: Item
    /// The longest side to decode, in pixels. Rows need little; the detail hero more.
    var maxPixels = 480
    @State private var image: CGImage?
    @State private var checked = false

    var body: some View {
        let key = ThumbnailCache.key(item, maxPixels: maxPixels)
        Group {
            if let image = image ?? ThumbnailCache.cached(key) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else if checked, let url = URL(string: item.thumbnailURL), !item.thumbnailURL.isEmpty {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .task(id: key) {
            image = await ThumbnailCache.load(key, file: ItemFiles(id: item.id).thumbnail, maxPixels: maxPixels)
            checked = true
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: item.kind.symbol)
                #if os(macOS)
                .font(.title2)
                #endif
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

enum ThumbnailCache {
    private nonisolated(unsafe) static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Changes when the picture may have: a new remote image, or the item captured again.
    static func key(_ item: Item, maxPixels: Int) -> String {
        "\(item.id.uuidString)|\(maxPixels)|\(item.thumbnailURL)|\(item.capturedAt?.timeIntervalSince1970 ?? 0)"
    }

    static func cached(_ key: String) -> CGImage? { images.object(forKey: key as NSString) }

    /// Decodes and downsamples the file in the background. Nil when there's no file yet.
    static func load(_ key: String, file: URL, maxPixels: Int) async -> CGImage? {
        if let hit = cached(key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { () -> Decoded? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
        }.value
        guard let image = decoded?.image else { return nil }
        images.setObject(image, forKey: key as NSString)
        return image
    }

    private struct Decoded: @unchecked Sendable { let image: CGImage }
}
