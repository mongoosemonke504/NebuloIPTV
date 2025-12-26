import SwiftUI
import ImageIO

// MARK: - 1. UTILITIES & TRANSITIONS
final class ImageCache: @unchecked Sendable {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 1024 * 1024 * 200
        return cache
    }()
    static func get(forKey key: String) -> UIImage? {
        shared.object(forKey: key as NSString)
    }
    static func set(_ image: UIImage, forKey key: String) {
        shared.setObject(image, forKey: key as NSString)
    }
}

struct CachedAsyncImage: View {
    let urlString: String
    let size: CGSize?
    @State private var image: UIImage?
    @State private var currentTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: size != nil ? .fill : .fit)
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .onAppear {
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
        let cacheKey = size != nil ? "\(urlString)-\(Int(size!.width))x\(Int(size!.height))" : urlString
        if let cached = ImageCache.get(forKey: cacheKey) {
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
                finalImage = downsample(imageData: data, to: targetSize, scale: scale)
            } else {
                finalImage = UIImage(data: data)
            }
            
            if let img = finalImage {
                ImageCache.set(img, forKey: cacheKey)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.image = img
                    }
                }
            }
        } catch { }
    }
    
    private func downsample(imageData: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, imageSourceOptions) else { return nil }
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
