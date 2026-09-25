import SwiftUI

/// The app canvas. Since the redesign this is simply pure black everywhere —
/// the old nebula gradient and custom-photo backgrounds were removed along
/// with their settings. Kept as a view (with its original signature) so the
/// screens that draw the background don't all need touching.
struct AppBackground: View {
    var body: some View { NebulaBackgroundView() }
}

struct NebulaBackgroundView: View {
    var color1: Color = .black
    var color2: Color = .black
    var color3: Color = .black
    var point1: UnitPoint = .top
    var point2: UnitPoint = .center
    var point3: UnitPoint = .bottom

    var body: some View {
        Color.black.ignoresSafeArea()
    }
}
