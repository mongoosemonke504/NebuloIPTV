import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 60)).foregroundColor(.gray)
            Text(title).font(.title2.bold()).foregroundColor(.white)
            Text(description).font(.body).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }
}
