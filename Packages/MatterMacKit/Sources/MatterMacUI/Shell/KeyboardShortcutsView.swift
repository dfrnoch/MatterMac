import SwiftUI

/// Help › Keyboard Shortcuts (⌘/): every shortcut MatterMac handles, grouped.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let keys: String
        let action: LocalizedStringKey
        var id: String { keys }
    }

    private let sections: [(title: LocalizedStringKey, items: [Shortcut])] = [
        ("Navigation", [
            .init(keys: "⌘K", action: "Quick switcher: channels and people"),
            .init(keys: "⌥↑ / ⌥↓", action: "Previous or next channel"),
            .init(keys: "⌥⇧↑ / ⌥⇧↓", action: "Previous or next unread channel"),
            .init(keys: "⌘1 … ⌘9", action: "Switch team"),
            .init(keys: "⇧⌘T", action: "Show or hide Threads"),
            .init(keys: "⇧⌘I", action: "Show or hide channel info"),
            .init(keys: "⌘F", action: "Search messages"),
            .init(keys: "⇧⌘M", action: "Recent mentions"),
            .init(keys: "⇧⌘L", action: "Browse channels"),
            .init(keys: "⇧⌘K", action: "New direct or group message"),
            .init(keys: "⌘0", action: "Show the main window"),
        ]),
        ("Messages", [
            .init(keys: "↩", action: "Send (or ⌘↩, per Settings)"),
            .init(keys: "⇧↩", action: "New line"),
            .init(keys: "↑", action: "Edit your last message (empty composer)"),
            .init(keys: "↩ on a selected message", action: "Reply in thread"),
            .init(keys: "⌃↩ on a selected message", action: "Message actions menu"),
            .init(keys: "Space on a selected message", action: "Preview its first image"),
            .init(keys: "esc", action: "Dismiss completion, selection, or cancel editing"),
        ]),
        ("Formatting", [
            .init(keys: "⌘B", action: "Bold"),
            .init(keys: "⌘I", action: "Italic"),
            .init(keys: "⇧⌘X", action: "Strikethrough"),
            .init(keys: "⌥⌘C", action: "Code (block for several lines)"),
            .init(keys: "⌥⌘K", action: "Link"),
            .init(keys: "@ ~ : /", action: "Mention, channel, emoji and command suggestions"),
        ]),
        ("App", [
            .init(keys: "⌘,", action: "Settings"),
            .init(keys: "⌘/", action: "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 20) {
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            ForEach(section.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: item.keys)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                                        .frame(minWidth: 90, alignment: .leading)
                                    Text(item.action).font(.callout)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 560)
    }
}
