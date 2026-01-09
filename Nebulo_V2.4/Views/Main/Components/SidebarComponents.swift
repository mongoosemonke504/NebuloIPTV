import SwiftUI
import Combine

struct GlassSidebarRow: View { let title: String; var icon: String? = nil; let isSelected: Bool; let accentColor: Color; var body: some View { HStack { if let icon = icon { Image(systemName: icon) }; Text(title) }.font(.callout).fontWeight(isSelected ? .semibold : .regular).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).modifier(GlassEffect(cornerRadius: 10, isSelected: isSelected, accentColor: accentColor)).animation(.easeInOut(duration: 0.2), value: isSelected) } }

struct ClockView: View { @State private var currentTime = Date(); let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect(); var body: some View { Text(currentTime, style: .time).font(.system(size: 32, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading).onReceive(timer) { input in currentTime = input }.foregroundStyle(.white) } }

// MARK: - EPG LOADING NOTIFICATION (APPLE STYLE)
struct EPGLoadingNotification: View {
    let progress: Double
    let accentColor: Color
    var onDismiss: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.1)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Fetching Updated Content")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Text("Live")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Fetching Content")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.leading, 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 25, x: 0, y: 12)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height < -10 { // Swipe up to hide
                        onDismiss?()
                    }
                }
        )
    }
}
