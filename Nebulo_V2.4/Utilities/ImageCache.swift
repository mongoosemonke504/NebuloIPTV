import Foundation
import SwiftUI
import UIKit

// Logic Helper
struct ImageCache {
    static func prefetchAndWait(urlString: String, size: CGSize) async {
        guard let url = URL(string: urlString) else { return }
        // Simple fire-and-forget prefetch (URLSession caches by default)
        let request = URLRequest(url: url)
        try? await URLSession.shared.data(for: request)
    }
}

// UI Component
struct CachedAsyncImage: View {
    let urlString: String
    let size: CGSize?
    
    var body: some View {
        AsyncImage(url: URL(string: urlString)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if phase.error != nil {
                Image(systemName: "photo") // Indicates an error.
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.gray)
            } else {
                ProgressView()
            }
        }
        .if(size != nil) { view in
            view.frame(width: size!.width, height: size!.height)
        }
    }
}