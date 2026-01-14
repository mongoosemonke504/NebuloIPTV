import SwiftUI

struct RecordingSetupSheet: View {
    let channel: StreamChannel
    let onDismiss: () -> Void
    
    @State private var startTime: Date
    @State private var endTime: Date
    @ObservedObject var recordingManager = RecordingManager.shared
    
    init(channel: StreamChannel, initialStartTime: Date = Date(), onDismiss: @escaping () -> Void) {
        self.channel = channel
        self.onDismiss = onDismiss
        _startTime = State(initialValue: initialStartTime)
        _endTime = State(initialValue: initialStartTime.addingTimeInterval(30 * 60))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Channel Info")) {
                    HStack {
                        if let icon = channel.icon {
                            CachedAsyncImage(urlString: icon, size: CGSize(width: 40, height: 40))
                        }
                        Text(channel.name)
                            .font(.headline)
                    }
                }
                
                Section(header: Text("Timing")) {
                    DatePicker("Start Time", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End Time", selection: $endTime, displayedComponents: [.date, .hourAndMinute])
                }
                
                Section {
                    Button(action: schedule) {
                        HStack {
                            Spacer()
                            Text("Start Recording")
                                .bold()
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Record Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
        }
    }
    
    func schedule() {
        
        if endTime <= startTime {
            
            
            endTime = startTime.addingTimeInterval(60)
        }
        
        let prog = ChannelViewModel.shared.getCurrentProgram(for: channel)
        
        recordingManager.scheduleRecording(
            channel: channel, 
            startTime: startTime, 
            endTime: endTime,
            programTitle: prog?.title,
            programDescription: prog?.description
        )
        onDismiss()
    }
}
