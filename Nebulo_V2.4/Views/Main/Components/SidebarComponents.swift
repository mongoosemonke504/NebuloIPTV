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

// MARK: - CLOCK VIEW
