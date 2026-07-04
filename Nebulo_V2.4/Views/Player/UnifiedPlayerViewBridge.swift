import SwiftUI
import UIKit

struct UnifiedPlayerViewBridge: UIViewRepresentable {
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        
        let view = NebuloPlayerEngine.shared.renderView
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // Remove from any previous superview to ensure it attaches to the current one
        view.removeFromSuperview()
        container.addSubview(view)
        
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        
        // Let touches pass through the renderView itself so the background Color.black.opacity(0.01) 
        // in SwiftUI can catch them for toggling controls.
        view.isUserInteractionEnabled = false 
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        
    }
}
