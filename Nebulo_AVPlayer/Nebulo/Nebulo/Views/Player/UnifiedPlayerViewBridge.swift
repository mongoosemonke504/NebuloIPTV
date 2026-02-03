import SwiftUI
import UIKit

struct UnifiedPlayerViewBridge: UIViewRepresentable {
    
    func makeUIView(context: Context) -> UIView {
        
        
        let view = NebuloPlayerEngine.shared.renderView
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        
    }
}
