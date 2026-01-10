import SwiftUI
import Combine

struct GlassSidebarRow: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundColor(accentColor)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(accentColor, lineWidth: 1.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                }
            }
        )
        .contentShape(Rectangle())
    }
}

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
