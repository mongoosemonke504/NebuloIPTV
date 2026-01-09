import Foundation
import SwiftUI

struct CachedAsyncImage: View {
    let urlString: String
    let size: CGSize
    
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
        .frame(width: size.width, height: size.height)
    }
}
