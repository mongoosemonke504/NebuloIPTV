import SwiftUI
import Combine

// MARK: - ROBUST IMAGE CACHE (Disk + Memory)
class ImageCache {
    static let shared = ImageCache()
    
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200 // Max 200 images in memory
        cache.totalCostLimit = 100 * 1024 * 1024 // Max 100MB in memory
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
        
        // Use downsampling for disk images to save memory
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
    
    func set(_ image: UIImage, forKey key: String, size: CGSize? = nil) {
        let cacheKey = (key + (size != nil ? "_\(Int(size!.width))x\(Int(size!.height))" : "")) as NSString
        cache.setObject(image, forKey: cacheKey)
        
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
    
    // High-performance downsampling logic
    private func downsample(imageAt imageURL: URL, to pointSize: CGSize, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
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
    
    static func prefetchAndWait(urlString: String, size: CGSize? = nil) async {
        if shared.hasImage(forKey: urlString) { return }
        guard let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                shared.set(image, forKey: urlString, size: size)
            }
        } catch {}
    }
    
    func prefetch(urlString: String, size: CGSize? = nil) {
        Task { await ImageCache.prefetchAndWait(urlString: urlString, size: size) }
    }
}

// MARK: - IMAGE LOADER
class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private let urlString: String
    private var task: Task<Void, Never>?
    
    init(urlString: String) {
        self.urlString = urlString
        // Synchronous check for immediate display ONLY if in memory cache
        if let cached = ImageCache.shared.getMemoryCache(forKey: urlString) {
            self.image = cached
            return
        }
        load()
    }
    
    func load() {
        if image != nil { return }
        
        task = Task {
            // Check full cache (Disk + Memory) in background task
            if let cached = ImageCache.shared.get(forKey: urlString) {
                await MainActor.run { self.image = cached }
                return
            }
            
            guard let url = URL(string: urlString) else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let downloadedImage = UIImage(data: data) {
                    ImageCache.shared.set(downloadedImage, forKey: urlString)
                    await MainActor.run { self.image = downloadedImage }
                }
            } catch {
                // Error
            }
        }
    }
    
    func cancel() {
        task?.cancel()
    }
}

// MARK: - CACHED ASYNC IMAGE VIEW
struct CachedAsyncImage: View {
    @StateObject private var loader: ImageLoader
    let size: CGSize?
    
    init(urlString: String, size: CGSize? = nil) {
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
                    Color.white.opacity(0.1) // Placeholder bg
                    if size != nil {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
            }
        }
        .applyIf(size != nil) { view in
            view.frame(width: size!.width, height: size!.height)
        }
        .onAppear {
            loader.load()
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

private extension String {
    var hashValueStr: String {
        return String(format: "%016llx", UInt64(bitPattern: Int64(self.hashValue)))
    }
}