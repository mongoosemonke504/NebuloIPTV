import SwiftUI
import ImageIO

// MARK: - 1. UTILITIES & TRANSITIONS
@MainActor
final class ImageCache: @unchecked Sendable {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 1024 * 1024 * 200
        return cache
    }()
    
    // File Manager for Disk Caching
    private static let fileManager = FileManager.default
    private static var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ImageCache")
    }
    
    static func setupDiskCache() {
        guard let url = cacheDirectory else { return }
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    
    static func get(forKey key: String) -> UIImage? {
        // 1. Check Memory
        if let memoryImage = shared.object(forKey: key as NSString) {
            return memoryImage
        }
        
        // 2. Check Disk
        guard let dir = cacheDirectory else { return nil }
        let fileURL = dir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            // Restore to memory
            shared.setObject(image, forKey: key as NSString)
            return image
        }
        
        return nil
    }
    
    static func set(_ image: UIImage, forKey key: String) {
        // 1. Save to Memory
        shared.setObject(image, forKey: key as NSString)
        
        // 2. Save to Disk (Background) - Extract data before task to avoid capturing UIImage
        let imageData = image.pngData()
        let dir = cacheDirectory
        Task.detached(priority: .background) {
            guard let dir = dir, let data = imageData else { return }
            let fileURL = dir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
            try? data.write(to: fileURL)
        }
    }

    static func prefetch(urlString: String, size: CGSize?) {
        setupDiskCache()
        guard let url = URL(string: urlString) else { return }
        let cacheKey = size != nil ? "\(urlString)-\(Int(size!.width))x\(Int(size!.height))" : urlString
        
        Task.detached(priority: .background) {
            let alreadyCached = await MainActor.run { get(forKey: cacheKey) != nil }
            if alreadyCached { return }
            
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                
                let scale = await MainActor.run {
                    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2.0
                }
                
                let finalImage: UIImage?
                if let targetSize = size {
                    finalImage = await MainActor.run { downsample(imageData: data, to: targetSize, scale: scale) }
                } else {
                    finalImage = UIImage(data: data)
                }
                
                if let img = finalImage {
                    await MainActor.run { set(img, forKey: cacheKey) }
                }
            } catch { }
        }
    }

    static func downsample(imageData: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, imageSourceOptions) else { return nil }
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue,
            kCGImageSourceShouldCacheImmediately: kCFBooleanTrue,
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimensionInPixels) as NSNumber
        ] as CFDictionary
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }
}

struct CachedAsyncImage: View {
    let urlString: String
    let size: CGSize?
    @State private var image: UIImage?
    @State private var currentTask: Task<Void, Never>?
    
    private var cacheKey: String {
        size != nil ? "\(urlString)-\(Int(size!.width))x\(Int(size!.height))" : urlString
    }
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: size != nil ? .fill : .fit)
            } else if let cached = ImageCache.get(forKey: cacheKey) {
                Image(uiImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: size != nil ? .fill : .fit)
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .onAppear {
            ImageCache.setupDiskCache()
            currentTask?.cancel()
            currentTask = Task { await load() }
        }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
        }
    }
    
    private func load() async {
        guard let url = URL(string: urlString) else { return }
        
        let cachedImage = await MainActor.run { ImageCache.get(forKey: cacheKey) }
        if let cached = cachedImage {
            await MainActor.run { self.image = cached }
            return
        }
        
        let scale = await MainActor.run {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2.0
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            
            let finalImage: UIImage?
            if let targetSize = size {
                finalImage = await MainActor.run { ImageCache.downsample(imageData: data, to: targetSize, scale: scale) }
            } else {
                finalImage = UIImage(data: data)
            }
            
            if let img = finalImage {
                await MainActor.run { ImageCache.set(img, forKey: cacheKey) }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.image = img
                    }
                }
            }
        } catch { }
    }
}
