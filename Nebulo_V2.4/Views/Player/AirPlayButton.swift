import SwiftUI
import AVKit

/// SwiftUI wrapper around `AVRoutePickerView` so the player chrome has an AirPlay icon
/// that opens the system route picker. Styled in white to match the existing glass buttons.
struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = tintColor
        picker.tintColor = tintColor
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = tintColor
        uiView.tintColor = tintColor
    }
}
