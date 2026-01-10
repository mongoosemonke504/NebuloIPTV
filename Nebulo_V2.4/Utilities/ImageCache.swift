import SwiftUI
import Combine

// MARK: - ROBUST IMAGE CACHE (Disk + Memory)
class ImageCache {
    static let shared = ImageCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    init() {
        // Create a dedicated subdirectory in Caches
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("NebuloImageCache", isDirectory: true)
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    func get(forKey key: String) -> UIImage? {
        let cacheKey = key as NSString
        
        // 1. Memory Cache
        if let image = cache.object(forKey: cacheKey) {
            return image
        }
        
        // 2. Disk Cache
        let safeName = key.hashValueStr
        let fileURL = cacheDirectory.appendingPathComponent(safeName)
        
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            // Restore to memory
            cache.setObject(image, forKey: cacheKey)
            return image
        }
        
        return nil
    }
    
    func hasImage(forKey key: String) -> Bool {
        if cache.object(forKey: key as NSString) != nil { return true }
        let safeName = key.hashValueStr
        let fileURL = cacheDirectory.appendingPathComponent(safeName)
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    func set(_ image: UIImage, forKey key: String) {
        let cacheKey = key as NSString
        
        // 1. Memory
        cache.setObject(image, forKey: cacheKey)
        
        // 2. Disk (Async)
        let safeName = key.hashValueStr
        let fileURL = cacheDirectory.appendingPathComponent(safeName)
        
        DispatchQueue.global(qos: .background).async {
            // Prefer PNG for quality, or JPEG
            if let data = image.pngData() {
                try? data.write(to: fileURL)
            }
        }
    }
    
    // Legacy support for ChannelViewModel
    static func prefetchAndWait(urlString: String, size: CGSize? = nil) async {
        if shared.get(forKey: urlString) != nil { return }
        
        guard let url = URL(string: urlString) else { return }
        
        // Use a simple URLSession request
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                shared.set(image, forKey: urlString)
            }
        } catch {
            // Ignore errors for prefetch
        }
    }
    
    // Instance method
    func prefetch(urlString: String) {
        Task { await ImageCache.prefetchAndWait(urlString: urlString) }
    }
}

// MARK: - IMAGE LOADER
class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private let urlString: String
    private var task: Task<Void, Never>?
    
    init(urlString: String) {
        self.urlString = urlString
        // Synchronous check for immediate display if cached
        if let cached = ImageCache.shared.get(forKey: urlString) {
            self.image = cached
            return
        }
        load()
    }
    
    func load() {
        if image != nil { return }
        
        task = Task {
            // Double check cache in task
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
        .if(size != nil) { view in
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