import SwiftUI
import UIKit

// MARK: - Unified Player Bridge
// This bridge simply presents the UIView that the active backend (KSPlayer/VLC) is drawing into.

struct UnifiedPlayerViewBridge: UIViewRepresentable {
    
    func makeUIView(context: Context) -> UIView {
        // We return the persistent render view from the engine.
        // This ensures that when the view appears, the player is already attached.
        let view = NebuloPlayerEngine.shared.renderView
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // No updates needed, the engine manages the view's content.
    }
}
