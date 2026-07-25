import SwiftUI
import Combine
@preconcurrency import Foundation

/// Wraps a decoded image so it can cross a `Task.detached` boundary without a
/// Sendable warning. Safe because the image is never mutated after decode.
private struct DecodedImage: @unchecked Sendable { let image: UIImage? }

@MainActor
final class ImageCache: @unchecked Sendable {

    static let shared = ImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // A larger resident set keeps logos/icons in memory across a scroll
        // session so re-appearing rows hit the memory cache instead of
        // re-decoding from disk on the main thread. Actual memory is bounded
        // by totalCostLimit below (each entry now reports a real byte cost),
        // so this count is just a ceiling.
        cache.countLimit = 512
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// On-disk cache directory. Computed from a nonisolated helper so the
    /// decode paths can locate it without hopping to the main actor.
    var cacheDirectory: URL { Self.diskCacheDirectory() }

    /// In-flight remote loads keyed by URL. Concurrent requests for the same
    /// image share one download + decode instead of each firing their own.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let dir = Self.diskCacheDirectory()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Synchronous cache access (memory + disk)

    /// Memory hit, or a disk decode promoted into memory. NOTE: the disk path
    /// decodes synchronously on the caller's thread — reserve it for one-shot
    /// callers (e.g. glow extraction). Scrolling views should use the async
    /// `image(forKey:)` so decoding stays off the main thread.
    func get(forKey key: String, size: CGSize? = nil) -> UIImage? {
        let cacheKey = Self.cacheKey(key, size)
        if let image = cache.object(forKey: cacheKey) { return image }
        guard let image = Self.decodeFromDisk(urlString: key, size: size) else { return nil }
        store(image, key: cacheKey)
        return image
    }

    func getMemoryCache(forKey key: String, size: CGSize? = nil) -> UIImage? {
        cache.object(forKey: Self.cacheKey(key, size))
    }

    func hasImage(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.fileURL(for: key).path)
    }

    func set(_ image: UIImage, forKey key: String, size: CGSize? = nil, skipDiskWrite: Bool = false) {
        store(image, key: Self.cacheKey(key, size))
        if skipDiskWrite { return }

        let fileURL = Self.fileURL(for: key)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            DispatchQueue.global(qos: .background).async {
                if let data = image.pngData() {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    private func store(_ image: UIImage, key: NSString) {
        cache.setObject(image, forKey: key, cost: Self.cost(of: image))
    }

    // MARK: - Async load (decode off the main thread, coalesced)

    /// Loads an image for display: memory → disk → network. Disk and network
    /// decoding run on a detached task so the main thread never blocks on
    /// image work, and concurrent requests for the same URL are coalesced.
    func image(forKey urlString: String, size: CGSize? = nil) async -> UIImage? {
        if let cached = cache.object(forKey: Self.cacheKey(urlString, size)) { return cached }
        if let existing = inFlight[urlString] { return await existing.value }

        let task = Task<UIImage?, Never> { [weak self] in
            // Disk decode, off the main thread.
            let disk = await Task.detached(priority: .userInitiated) {
                DecodedImage(image: ImageCache.decodeFromDisk(urlString: urlString, size: size))
            }.value.image
            if let disk {
                self?.store(disk, key: Self.cacheKey(urlString, size))
                return disk
            }

            // Network fetch (transfer is already off-main), then decode + persist off-main.
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                DecodedImage(image: UIImage(data: data))
            }.value.image
            guard let image = decoded else { return nil }

            let fileURL = ImageCache.fileURL(for: urlString)
            DispatchQueue.global(qos: .background).async {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try? data.write(to: fileURL)
                }
            }
            self?.store(image, key: Self.cacheKey(urlString, size))
            return image
        }

        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil
        return result
    }

    // MARK: - Prefetch

    /// Warms the MEMORY cache for a URL without touching the main thread.
    /// A disk-only warm isn't enough: list rows built mid-transition do a
    /// synchronous memory lookup first and fall back to a main-thread disk
    /// decode — with dozens of crests that decode queue made the soccer
    /// rows pop in one after another instead of landing together. Promoting
    /// the disk copy into memory here means every row hits the instant path.
    nonisolated static func prefetchAndWait(urlString: String, size: CGSize? = nil) async {
        if await shared.getMemoryCache(forKey: urlString, size: size) != nil { return }

        if FileManager.default.fileExists(atPath: fileURL(for: urlString).path) {
            let decoded = await Task.detached(priority: .utility) {
                DecodedImage(image: decodeFromDisk(urlString: urlString, size: size))
            }.value.image
            if let image = decoded {
                await shared.set(image, forKey: urlString, size: size, skipDiskWrite: true)
            }
            return
        }

        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        try? data.write(to: fileURL(for: urlString))
        let decoded = await Task.detached(priority: .background) {
            DecodedImage(image: UIImage(data: data))
        }.value.image
        if let image = decoded {
            await shared.set(image, forKey: urlString, size: size, skipDiskWrite: true)
        }
    }

    func prefetch(urlString: String, size: CGSize? = nil) {
        Task.detached { await ImageCache.prefetchAndWait(urlString: urlString, size: size) }
    }

    // MARK: - Nonisolated helpers (safe to call off the main actor)

    nonisolated static func diskCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NebuloImageCache", isDirectory: true)
    }

    nonisolated private static func fileURL(for key: String) -> URL {
        diskCacheDirectory().appendingPathComponent(key.hashValueStr)
    }

    nonisolated private static func cacheKey(_ key: String, _ size: CGSize?) -> NSString {
        (key + (size != nil ? "_\(Int(size!.width))x\(Int(size!.height))" : "")) as NSString
    }

    nonisolated private static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage { return cg.bytesPerRow * cg.height }
        return Int(image.size.width * image.size.height * 4)
    }

    nonisolated static func decodeFromDisk(urlString: String, size: CGSize? = nil) -> UIImage? {
        let fileURL = fileURL(for: urlString)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return downsample(imageAt: fileURL, to: size ?? CGSize(width: 300, height: 300))
    }

    nonisolated private static func downsample(imageAt imageURL: URL, to pointSize: CGSize, scale: CGFloat = 2.0) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions) else { return nil }

        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }
}

@MainActor
class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    /// The last requested URL fetched and came back empty (404, bad data).
    /// Views use this to swap the spinner for a static fallback instead of
    /// spinning forever — player headshots 404 constantly on ESPN's CDN.
    @Published var failed = false
    let urlString: String
    /// Decode at this size instead of the shared 300x300 default. Opt-in, so
    /// only the callers that need a big photographic image pay for one — the
    /// cache is keyed by (url, size), so the two never collide.
    let decodeSize: CGSize?
    private var loadedURL: String? = nil

    init(urlString: String, decodeSize: CGSize? = nil) {
        self.urlString = urlString
        self.decodeSize = decodeSize
        // Populate synchronously from memory OR disk cache so the first
        // frame never shows a placeholder for an already-cached image.
        // Without the disk fallback, rows created mid-transition (e.g. the
        // directional sport swipe) rendered gray boxes for a beat and their
        // logos popped in after the slide instead of moving with it.
        if let cached = ImageCache.shared.getMemoryCache(forKey: urlString, size: decodeSize)
            ?? ImageCache.shared.get(forKey: urlString, size: decodeSize) {
            self.image = cached
            self.loadedURL = urlString
        }
    }

    // targetURL allows callers to request a different URL than the one the
    // loader was initialised with — needed when @StateObject preserves the
    // loader instance across channel changes.
    func loadAsync(targetURL: String? = nil) async {
        let url = targetURL ?? urlString
        // No URL at all is a failure too — otherwise the view spins forever.
        guard !url.isEmpty else { failed = true; return }

        // Already showing the right image — nothing to do.
        if loadedURL == url { return }

        // Memory cache — instant, no flicker.
        if let cached = ImageCache.shared.getMemoryCache(forKey: url, size: decodeSize) {
            image = cached
            loadedURL = url
            return
        }

        // Disk/network via the shared coalesced loader — decode runs off the
        // main thread. The current image is kept on screen until the new one
        // is ready, so a channel switch never flashes a spinner for an image
        // that was already cached on disk.
        let loaded = await ImageCache.shared.image(forKey: url, size: decodeSize)
        guard !Task.isCancelled, loadedURL != url else { return }
        if let loaded {
            image = loaded
            loadedURL = url
            failed = false
        } else {
            failed = true
        }
    }
}

struct CachedAsyncImage: View {
    @StateObject private var loader: ImageLoader
    private let urlString: String
    let size: CGSize?
    /// Shown instead of the spinner once the fetch has definitively failed
    /// (missing headshots, dead logo URLs) — a spinner that never resolves
    /// reads as broken.
    let failurePlaceholder: AnyView?
    /// `.fit` letterboxes (right for logos); `.fill` crops to the frame, which
    /// is what a photographic still wants.
    let contentMode: ContentMode

    init(urlString: String,
         size: CGSize? = nil,
         contentMode: ContentMode = .fit,
         decodeSize: CGSize? = nil,
         failurePlaceholder: AnyView? = nil) {
        self.urlString = urlString
        _loader = StateObject(wrappedValue: ImageLoader(urlString: urlString, decodeSize: decodeSize))
        self.size = size
        self.contentMode = contentMode
        self.failurePlaceholder = failurePlaceholder
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loader.failed {
                if let failurePlaceholder {
                    failurePlaceholder
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        if size != nil {
                            Image(systemName: "photo")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    if size != nil {
                        CustomSpinner(color: .white.opacity(0.5), lineWidth: 2, size: 15)
                    }
                }
            }
        }
        .applyIf(size != nil) { view in
            view.frame(width: size!.width, height: size!.height)
        }
        // .task(id:) fires when the view appears and re-fires on URL change
        // (e.g. channel switch) — passes the new URL so the persisted
        // @StateObject loader fetches the correct image.
        .task(id: urlString) {
            await loader.loadAsync(targetURL: urlString)
        }
    }
}

private extension String {
    /// Stable FNV-1a 64-bit hash for disk-cache filenames. The previous
    /// implementation used `String.hashValue`, which Swift RANDOMIZES on
    /// every launch — so all disk-cached images became unreachable each
    /// session and had to be re-downloaded. That hit the soccer tabs
    /// hardest: their large logo sets get evicted from the memory cache,
    /// and the disk copies from earlier sessions could never be found.
    nonisolated var hashValueStr: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
