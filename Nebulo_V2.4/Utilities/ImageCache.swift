import SwiftUI
import Combine
@preconcurrency import Foundation

@MainActor

final class ImageCache: @unchecked Sendable {

    static let shared = ImageCache()

    

    private let cache: NSCache<NSString, UIImage> = {

        let cache = NSCache<NSString, UIImage>()

        cache.countLimit = 200 

        cache.totalCostLimit = 100 * 1024 * 1024 

        return cache

    }()

    

    private let fileManager = FileManager.default

    private let cacheDirectory: URL

    

    init() {

        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)

        cacheDirectory = paths[0].appendingPathComponent("NebuloImageCache", isDirectory: true)

        

        if !fileManager.fileExists(atPath: cacheDirectory.path) {

            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        }

    }

    

    func get(forKey key: String, size: CGSize? = nil) -> UIImage? {

        let cacheKey = (key + (size != nil ? "_\(Int(size!.width))x\(Int(size!.height))" : "")) as NSString

        

        if let image = cache.object(forKey: cacheKey) {

            return image

        }

        

        let safeName = key.hashValueStr

        let fileURL = cacheDirectory.appendingPathComponent(safeName)

        

        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        

        

        if let image = downsample(imageAt: fileURL, to: size ?? CGSize(width: 300, height: 300)) {

            cache.setObject(image, forKey: cacheKey)

            return image

        }

        

        return nil

    }

    

    func getMemoryCache(forKey key: String, size: CGSize? = nil) -> UIImage? {

        let cacheKey = (key + (size != nil ? "_\(Int(size!.width))x\(Int(size!.height))" : "")) as NSString

        return cache.object(forKey: cacheKey)

    }

    

    func hasImage(forKey key: String) -> Bool {

        let safeName = key.hashValueStr

        let fileURL = cacheDirectory.appendingPathComponent(safeName)

        return fileManager.fileExists(atPath: fileURL.path)

    }

    

    func set(_ image: UIImage, forKey key: String, size: CGSize? = nil, skipDiskWrite: Bool = false) {

        let cacheKey = (key + (size != nil ? "_\(Int(size!.width))x\(Int(size!.height))" : "")) as NSString

        cache.setObject(image, forKey: cacheKey)

        

        if skipDiskWrite { return }

        

        let safeName = key.hashValueStr

        let fileURL = cacheDirectory.appendingPathComponent(safeName)

        

        if !fileManager.fileExists(atPath: fileURL.path) {

            DispatchQueue.global(qos: .background).async {

                if let data = image.pngData() {

                    try? data.write(to: fileURL)

                }

            }

        }

    }

    

    

    private func downsample(imageAt imageURL: URL, to pointSize: CGSize, scale: CGFloat? = nil) -> UIImage? {

        let actualScale = scale ?? 2.0 

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions) else { return nil }

        

        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * actualScale

        let downsampleOptions = [

            kCGImageSourceCreateThumbnailFromImageAlways: true,

            kCGImageSourceShouldCacheImmediately: true,

            kCGImageSourceCreateThumbnailWithTransform: true,

            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels

        ] as CFDictionary

        

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }

        return UIImage(cgImage: downsampledImage)

    }

    

    static func prefetchAndWait(urlString: String, size: CGSize? = nil) async {

        if shared.hasImage(forKey: urlString) { return }

        guard let url = URL(string: urlString) else { return }

        

        do {

            let (data, _) = try await URLSession.shared.data(from: url)

            if let image = UIImage(data: data) {

                

                let safeName = urlString.hashValueStr

                let fileURL = shared.cacheDirectory.appendingPathComponent(safeName)

                try? data.write(to: fileURL)

                

                

                shared.set(image, forKey: urlString, size: size, skipDiskWrite: true)

            }

        } catch {}

    }

    

    func prefetch(urlString: String, size: CGSize? = nil) {

        Task { await ImageCache.prefetchAndWait(urlString: urlString, size: size) }

    }

}

@MainActor
class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    let urlString: String
    private var loadedURL: String? = nil

    init(urlString: String) {
        self.urlString = urlString
        // Populate synchronously from memory OR disk cache so the first
        // frame never shows a placeholder for an already-cached image.
        // Without the disk fallback, rows created mid-transition (e.g. the
        // directional sport swipe) rendered gray boxes for a beat and their
        // logos popped in after the slide instead of moving with it. The
        // disk read is a small downsampled decode — the loader already does
        // the same synchronous read on MainActor in loadAsync.
        if let cached = ImageCache.shared.getMemoryCache(forKey: urlString)
            ?? ImageCache.shared.get(forKey: urlString) {
            self.image = cached
            self.loadedURL = urlString
        }
    }

    // targetURL allows callers to request a different URL than the one the
    // loader was initialised with — needed when @StateObject preserves the
    // loader instance across channel changes.
    func loadAsync(targetURL: String? = nil) async {
        let url = targetURL ?? urlString
        guard !url.isEmpty else { return }

        // Already showing the right image — nothing to do.
        if loadedURL == url { return }

        // Memory cache — instant, no flicker.
        if let cached = ImageCache.shared.getMemoryCache(forKey: url) {
            image = cached
            loadedURL = url
            return
        }

        // Clear stale image so the spinner shows while the new one loads.
        image = nil

        // Disk cache — synchronous read but we're already on MainActor.
        if let cached = ImageCache.shared.get(forKey: url) {
            image = cached
            loadedURL = url
            return
        }

        guard let imageURL = URL(string: url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            // Bail out if the view disappeared while we were downloading.
            guard !Task.isCancelled else { return }
            if let downloaded = UIImage(data: data) {
                ImageCache.shared.set(downloaded, forKey: url)
                image = downloaded
                loadedURL = url
            }
        } catch {
            // Covers cancellation and network errors — nothing to do.
        }
    }
}

struct CachedAsyncImage: View {
    @StateObject private var loader: ImageLoader
    private let urlString: String
    let size: CGSize?

    init(urlString: String, size: CGSize? = nil) {
        self.urlString = urlString
        _loader = StateObject(wrappedValue: ImageLoader(urlString: urlString))
        self.size = size
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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