import SwiftUI
import MatterMacModels
import MatterMacCore

/// Sets or clears the signed-in user's custom status (an explicit server change,
/// visible to other users). Presets match the official clients.
struct CustomStatusView: View {
    let session: SessionViewModel
    let current: CustomStatus?
    @State private var emoji = ""
    @State private var text = ""
    @State private var duration: CustomStatusDuration = .today
    @Environment(\.dismiss) private var dismiss

    private static let presets: [(emoji: String, text: LocalizedStringResource, duration: CustomStatusDuration)] = [
        ("calendar", "In a meeting", .oneHour),
        ("hamburger", "Out for lunch", .thirtyMinutes),
        ("sneezing_face", "Out sick", .today),
        ("house", "Working from home", .today),
        ("palm_tree", "On a vacation", .thisWeek),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set a Status").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Text(EmojiText.display(emoji.isEmpty ? "speech_balloon" : emoji))
                    .font(.title2)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                TextField("Emoji name, e.g. palm_tree", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityLabel("Emoji name")
                TextField("What’s your status?", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("Status text")
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.presets.indices, id: \.self) { index in
                    let preset = Self.presets[index]
                    Button {
                        emoji = preset.emoji
                        text = String(localized: preset.text)
                        duration = preset.duration
                    } label: {
                        HStack(spacing: 8) {
                            Text(EmojiText.display(preset.emoji)).frame(width: 22)
                            Text(preset.text)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Clear after", selection: $duration) {
                Text("Don’t clear").tag(CustomStatusDuration.dontClear)
                Text("30 minutes").tag(CustomStatusDuration.thirtyMinutes)
                Text("1 hour").tag(CustomStatusDuration.oneHour)
                Text("4 hours").tag(CustomStatusDuration.fourHours)
                Text("Today").tag(CustomStatusDuration.today)
                Text("This week").tag(CustomStatusDuration.thisWeek)
            }
            .frame(width: 260)
            Text("Your status is visible to everyone on this server.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if current != nil {
                    Button("Clear Status", role: .destructive) {
                        session.setCustomStatus(emoji: "", text: "", duration: .dontClear)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(emoji.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            emoji = current?.emoji ?? ""
            text = current?.text ?? ""
        }
    }

    private func save() {
        guard !(emoji.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty) else { return }
        session.setCustomStatus(emoji: emoji, text: text, duration: duration)
        dismiss()
    }
}
