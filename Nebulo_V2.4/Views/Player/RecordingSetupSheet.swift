import SwiftUI

// MARK: - Setup mode

private enum SetupMode: String, CaseIterable {
    case guide   = "From Guide"
    case manual  = "Manual"
}

// MARK: - Main sheet

struct RecordingSetupSheet: View {
    let channel: StreamChannel
    let onDismiss: () -> Void

    @State private var mode: SetupMode = .guide
    @State private var selectedProgram: EPGProgram? = nil
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var selectedCategory: Recording.RecordingCategory = .other
    @State private var didSchedule = false

    @ObservedObject private var recordingManager = RecordingManager.shared

    // EPG programs for this channel (today + tomorrow, future ones first)
    private var upcomingPrograms: [EPGProgram] {
        guard let epgID = channel.epgID,
              let programs = ChannelViewModel.shared.epgData[epgID]
        else { return [] }
        let cutoff = Date().addingTimeInterval(-300) // allow currently-airing
        let limit  = Date().addingTimeInterval(48 * 3600)
        return programs
            .filter { $0.stop > cutoff && $0.start < limit }
            .sorted { $0.start < $1.start }
    }

    init(channel: StreamChannel, initialStartTime: Date = Date(), onDismiss: @escaping () -> Void) {
        self.channel = channel
        self.onDismiss = onDismiss
        _startTime = State(initialValue: initialStartTime)
        _endTime   = State(initialValue: initialStartTime.addingTimeInterval(30 * 60))
        // If we have a current program, pre-select it
        if let prog = ChannelViewModel.shared.getCurrentProgram(for: channel) {
            _selectedProgram = State(initialValue: prog)
            _startTime = State(initialValue: max(prog.start, initialStartTime))
            _endTime   = State(initialValue: prog.stop)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                // Header
                HStack(spacing: 14) {
                    if let icon = channel.icon {
                        CachedAsyncImage(urlString: icon, size: CGSize(width: 44, height: 44))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Record")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        Text(channel.name)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

                // Mode picker
                HStack(spacing: 0) {
                    ForEach(SetupMode.allCases, id: \.self) { m in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { mode = m }
                        } label: {
                            Text(m.rawValue)
                                .font(.system(size: 14, weight: mode == m ? .semibold : .regular))
                                .foregroundStyle(mode == m ? .white : .white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(mode == m ? Color.white.opacity(0.15) : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)

                Divider().background(Color.white.opacity(0.12))

                // Content
                if mode == .guide {
                    guideContent
                } else {
                    manualContent
                }

                Divider().background(Color.white.opacity(0.12))

                // Category
                categoryPicker
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                // Buttons
                actionButtons
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
        .onAppear {
            // Auto-select guide mode if programs are available, manual otherwise
            if upcomingPrograms.isEmpty { mode = .manual }
        }
    }

    // MARK: - Guide content

    private var guideContent: some View {
        ScrollView(showsIndicators: false) {
            if upcomingPrograms.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No guide data available.\nUse Manual mode to set a time.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(upcomingPrograms) { prog in
                        guideProgramRow(prog)
                        Divider().background(Color.white.opacity(0.07)).padding(.leading, 20)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder
    private func guideProgramRow(_ prog: EPGProgram) -> some View {
        let isSelected = selectedProgram?.id == prog.id
        let isNow = prog.start <= Date() && prog.stop > Date()
        let isPast = prog.stop < Date()

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedProgram = prog
                startTime = max(prog.start, Date())
                endTime   = prog.stop
            }
        } label: {
            HStack(spacing: 14) {
                // Time column
                VStack(alignment: .trailing, spacing: 2) {
                    Text(shortTime(prog.start))
                        .font(.system(size: 12, design: .monospaced).weight(isNow ? .bold : .regular))
                        .foregroundStyle(isNow ? .white : .white.opacity(isPast ? 0.3 : 0.55))
                    Text(durationLabel(prog))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(width: 50, alignment: .trailing)

                // Accent bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.red : (isNow ? Color.red.opacity(0.5) : Color.white.opacity(0.12)))
                    .frame(width: 3, height: 34)

                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(prog.title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isPast ? .white.opacity(0.35) : .white.opacity(isSelected ? 1 : 0.75))
                        .lineLimit(1)
                    if isNow { liveTag }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Checkmark if selected
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 18))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isSelected ? Color.red.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
    }

    private var liveTag: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 5, height: 5)
            Text("LIVE")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Manual content

    private var manualContent: some View {
        VStack(spacing: 0) {
            timeRow(label: "Start", date: $startTime)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 20)
            timeRow(label: "End", date: $endTime)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func timeRow(label: String, date: Binding<Date>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .colorScheme(.dark)
        }
    }

    // MARK: - Category picker

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: 8) {
                ForEach(Recording.RecordingCategory.allCases, id: \.self) { cat in
                    Button { selectedCategory = cat } label: {
                        Text(cat.displayName)
                            .font(.system(size: 13, weight: selectedCategory == cat ? .semibold : .regular))
                            .foregroundStyle(selectedCategory == cat ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selectedCategory == cat ? cat.color.opacity(0.35) : Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(selectedCategory == cat ? cat.color.opacity(0.7) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: schedule) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text(scheduleButtonLabel)
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canSchedule)
            .opacity(canSchedule ? 1 : 0.5)

            Button(action: onDismiss) {
                Text("Cancel")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Logic

    private var canSchedule: Bool {
        if mode == .guide { return selectedProgram != nil }
        return endTime > startTime
    }

    private var scheduleButtonLabel: String {
        if mode == .guide, let prog = selectedProgram {
            return "Record \"\(prog.title)\""
        }
        return "Schedule Recording"
    }

    private func schedule() {
        var finalStart = startTime
        var finalEnd   = endTime
        var title: String?
        var desc: String?

        if mode == .guide, let prog = selectedProgram {
            finalStart = max(prog.start, Date())
            finalEnd   = prog.stop
            title = prog.title
            desc  = prog.description
        }

        guard finalEnd > finalStart else { return }

        recordingManager.scheduleRecording(
            channel: channel,
            startTime: finalStart,
            endTime: finalEnd,
            programTitle: title,
            programDescription: desc,
            category: selectedCategory
        )
        onDismiss()
    }

    // MARK: - Helpers

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private func durationLabel(_ prog: EPGProgram) -> String {
        let mins = Int(prog.stop.timeIntervalSince(prog.start) / 60)
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
