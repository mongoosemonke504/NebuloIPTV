import SwiftUI

struct VLCControlsView: View {
    @Binding var isPlaying: Bool
    @Binding var progress: Float
    @Binding var isScrubbing: Bool
    let duration: Double 
    
    var onSeek: (Float) -> Void
    var onClose: () -> Void
    var onInteraction: () -> Void
    var onTapBackground: () -> Void
    
    @State private var scrubTimeStr: String? = nil
    
    var body: some View {
        ZStack {
            
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTapBackground()
                }
                .ignoresSafeArea()
            
            VStack {
                
                HStack {
                    Button(action: { onClose(); onInteraction() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    Spacer()
                }
                .padding()
                
                Spacer()
                
                
                VStack(spacing: 12) {
                    
                    Slider(value: $progress, in: 0...1) { editing in
                        isScrubbing = editing
                        onInteraction()
                        if !editing {
                            onSeek(progress)
                            scrubTimeStr = nil
                        }
                    }
                    .accentColor(.red)
                    
                    HStack {
                        Text(scrubTimeStr ?? formatTime(Double(progress) * duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        
                        Button(action: { isPlaying.toggle(); onInteraction() }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 34))
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                        
                        Text(formatTime(duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white)
                    }
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
            }
        }
        .onChange(of: progress) { newProgress in
            if isScrubbing {
                scrubTimeStr = formatTime(Double(newProgress) * duration)
            }
        }
    }
    
    private func formatTime(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        let m = (s % 3600) / 60
        let sec = s % 60
        let h = s / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
