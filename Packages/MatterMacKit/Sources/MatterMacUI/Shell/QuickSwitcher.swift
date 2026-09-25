import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// ⌘K quick switcher presented as a floating glass palette over the main window:
/// a faint scrim that closes on click, and the palette near the top. The field's
/// focus is taken on open and the previous first responder (usually the composer)
/// is restored on close.
struct QuickSwitcherOverlay: View {
    @Bindable var session: SessionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each presentation is a new palette, even when reopened during the closing
    /// transition (which would otherwise revive the previous one and its query).
    @State private var presentation = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if session.isQuickSwitcherVisible {
                    Color.black.opacity(0.06)
                        .contentShape(Rectangle())
                        .onTapGesture { session.isQuickSwitcherVisible = false }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    let top = QuickSwitcherMetrics.topInset(forHeight: geometry.size.height)
                    QuickSwitcherView(session: session)
                        .id(presentation)
                        .frame(maxHeight: QuickSwitcherMetrics.panelHeight(forAvailable: geometry.size.height - top))
                        .shadow(color: .black.opacity(0.16), radius: 28, y: 14)
                        .padding(.top, top)
                        .padding(.horizontal, 24)
                        .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(session.isQuickSwitcherVisible)
        .background(ResponderRestorer(isPresented: session.isQuickSwitcherVisible))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.isQuickSwitcherVisible)
        .onChange(of: session.isQuickSwitcherVisible) { _, visible in
            if !visible { presentation &+= 1 }
        }
    }
}

enum QuickSwitcherMetrics {
    static let width: CGFloat = 640
    static let maxHeight: CGFloat = 460
    static let cornerRadius: CGFloat = 24
    static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40
    static let leadingSize: CGFloat = 28

    /// Below the toolbar, a little higher than centered, as Spotlight sits.
    static func topInset(forHeight height: CGFloat) -> CGFloat {
        max(12, min(96, (height - maxHeight) * 0.3))
    }

    static func panelHeight(forAvailable available: CGFloat) -> CGFloat {
        max(fieldHeight + rowHeight * 3, min(maxHeight, available - 16))
    }
}

/// Query, results and selection of one presentation of the palette.
@Observable
final class QuickSwitcherModel {
    let session: SessionViewModel
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    private(set) var results: [QuickSwitchItem] = []
    private(set) var hasLoaded = false
    var selection: QuickSwitchItem.Kind?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(session: SessionViewModel) {
        self.session = session
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Results arrive after a short debounce; the first load is immediate.
    func schedule(immediately: Bool = false) {
        searchTask?.cancel()
        let text = query
        searchTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let session = self?.session else { return }
            let found = await session.quickSwitcherResults(text)
            guard !Task.isCancelled, let self else { return }
            results = found
            hasLoaded = true
            selection = found.first?.kind
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.kind == selection } ?? -1
        selection = results[max(0, min(results.count - 1, index + delta))].kind
    }

    func openSelection() {
        guard let item = results.first(where: { $0.kind == selection }) ?? results.first else { return }
        open(item)
    }

    func open(_ item: QuickSwitchItem) {
        cancel()
        session.open(item)
    }

    func close() {
        cancel()
        session.isQuickSwitcherVisible = false
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }
}

/// Test hook: the palette registers its model here when it appears.
final class QuickSwitcherProbe {
    weak var model: QuickSwitcherModel?
}

extension EnvironmentValues {
    @Entry var quickSwitcherProbe: QuickSwitcherProbe?
}

/// The palette itself: search field, sectioned results and a key-hint footer.
struct QuickSwitcherView: View {
    @State private var model: QuickSwitcherModel
    @FocusState private var focused: Bool
    @Environment(\.quickSwitcherProbe) private var probe

    init(session: SessionViewModel) {
        _model = State(initialValue: QuickSwitcherModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().padding(.horizontal, 14)
            resultsArea
                .frame(maxHeight: .infinity)
            Divider().padding(.horizontal, 14)
            QuickSwitcherFooter()
        }
        .frame(width: QuickSwitcherMetrics.width)
        .frame(maxHeight: QuickSwitcherMetrics.maxHeight)
        .glassSurface(cornerRadius: QuickSwitcherMetrics.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Quick switcher")
        .onAppear {
            focused = true
            model.schedule(immediately: true)
            probe?.model = model
        }
        .onChange(of: focused) { _, isFocused in
            // The palette is modal: typing always goes to its field, even if the
            // sidebar or a loading conversation claims focus meanwhile.
            if !isFocused, model.session.isQuickSwitcherVisible { focused = true }
        }
        .onDisappear { model.cancel() }
        .onExitCommand { model.close() }
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Switch to a channel or person…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
                .onSubmit { model.openSelection() }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.escape) { model.close(); return .handled }
                .onKeyPress(keys: ["n", "p"]) { press in
                    guard press.modifiers == .control else { return .ignored }
                    model.move(press.key == "n" ? 1 : -1)
                    return .handled
                }
                .accessibilityLabel("Quick switcher")
                .accessibilityHint("Type a channel or person, then use the arrow keys and Return to open.")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: QuickSwitcherMetrics.fieldHeight)
    }

    @ViewBuilder private var resultsArea: some View {
        if model.results.isEmpty {
            if model.hasLoaded {
                QuickSwitcherEmptyState(hasQuery: model.hasQuery)
            } else {
                Color.clear
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(QuickSwitcherGroup.groups(model.results)) { group in
                            if let title = group.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, group.isFirst ? 4 : 10)
                                    .padding(.bottom, 3)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group.items) { item in
                                QuickSwitcherRow(item: item, session: model.session,
                                                 isSelected: item.kind == model.selection) {
                                    model.open(item)
                                }
                                .id(item.kind)
                            }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selection) {
                    guard let selection = model.selection else { return }
                    proxy.scrollTo(selection)
                }
            }
        }
    }
}

/// Consecutive results of one section, with the header shown for it (if any).
struct QuickSwitcherGroup: Identifiable {
    let section: QuickSwitchItem.Section
    let title: String?
    let items: [QuickSwitchItem]
    let isFirst: Bool
    var id: String { "\(section)-\(items.first.map { "\($0.kind)" } ?? "")" }

    /// Unread, Recent and People are always titled; ranked matches only when
    /// people follow them.
    static func groups(_ items: [QuickSwitchItem]) -> [QuickSwitcherGroup] {
        var runs: [(QuickSwitchItem.Section, [QuickSwitchItem])] = []
        for item in items {
            if let last = runs.last, last.0 == item.section {
                runs[runs.count - 1].1.append(item)
            } else {
                runs.append((item.section, [item]))
            }
        }
        let hasPeople = runs.contains { $0.0 == .people }
        return runs.enumerated().map { index, run in
            let title: String? = switch run.0 {
            case .unread: String(localized: "Unread")
            case .recent: String(localized: "Recent")
            case .matches: hasPeople ? String(localized: "Conversations") : nil
            case .people: String(localized: "People")
            }
            return QuickSwitcherGroup(section: run.0, title: title, items: run.1, isFirst: index == 0)
        }
    }
}

enum QuickSwitcherText {
    static func kind(_ item: QuickSwitchItem) -> String {
        if case .user = item.kind { return String(localized: "person") }
        switch item.channelType {
        case .direct?: return String(localized: "direct message")
        case .group?: return String(localized: "group message")
        case .private?: return String(localized: "private channel")
        default: return String(localized: "channel")
        }
    }

    static func accessibilityLabel(_ item: QuickSwitchItem) -> String {
        var parts = [item.title, kind(item)]
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if item.mentionCount > 0 { parts.append(String(localized: "\(item.mentionCount) mentions")) }
        else if item.isUnread { parts.append(String(localized: "unread")) }
        if item.isArchived, !item.subtitle.localizedCaseInsensitiveContains(String(localized: "Archived")) {
            parts.append(String(localized: "archived"))
        }
        if item.isMuted { parts.append(String(localized: "muted")) }
        if let presence = item.presence, item.channelType == .direct { parts.append(presence.label) }
        return parts.joined(separator: ", ")
    }

    static func badge(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

struct QuickSwitcherRow: View {
    let item: QuickSwitchItem
    let session: SessionViewModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                QuickSwitcherLeading(item: item, session: session)
                    .frame(width: QuickSwitcherMetrics.leadingSize, height: QuickSwitcherMetrics.leadingSize)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: item.title)
                        .font(.system(size: 14, weight: item.isUnread ? .semibold : .regular))
                        .foregroundStyle(item.isArchived ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !item.subtitle.isEmpty {
                        Text(verbatim: item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 200, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 8)
            .frame(height: QuickSwitcherMetrics.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.tint.opacity(0.2))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(item.isMuted && item.mentionCount == 0 ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .help(item.subtitle.isEmpty ? item.title : item.title + " — " + item.subtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuickSwitcherText.accessibilityLabel(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if item.mentionCount > 0 {
                Text(QuickSwitcherText.badge(item.mentionCount))
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 18)
                    .background(Capsule().fill(.tint))
            } else if item.isUnread {
                Circle().fill(.tint).frame(width: 8, height: 8)
            }
            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Leading visual: the person's avatar with presence, overlapping avatars for a
/// group message, or a `#`/lock tile for channels.
struct QuickSwitcherLeading: View {
    let item: QuickSwitchItem
    let session: SessionViewModel
    private let size = QuickSwitcherMetrics.leadingSize

    var body: some View {
        switch item.channelType {
        case .direct? where !item.people.isEmpty:
            let person = item.people[0]
            ProfileAvatar(session: session, userID: person.id, revision: person.revision, name: person.name,
                          size: size, status: item.presence)
        case .group? where item.people.count >= 2:
            // Two overlapping avatars, the front one ringed to separate them.
            let small = floor(size * 0.64)
            ZStack {
                ProfileAvatar(session: session, userID: item.people[0].id, revision: item.people[0].revision,
                              name: item.people[0].name, size: small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ProfileAvatar(session: session, userID: item.people[1].id, revision: item.people[1].revision,
                              name: item.people[1].name, size: small)
                    .padding(1.5)
                    .background(Circle().fill(.background))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 1.5, y: 1.5)
            }
            .frame(width: size, height: size)
        default:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay {
                    Image(systemName: glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var glyph: String {
        if item.isArchived { return "archivebox" }
        switch item.channelType {
        case .direct?: return "person.fill"
        case .group?: return "person.2.fill"
        case .private?: return "lock.fill"
        default: return "number"
        }
    }
}

private struct QuickSwitcherEmptyState: View {
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasQuery ? "magnifyingglass" : "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasQuery ? "No Matches" : "No Conversations Yet")
                .font(.headline)
            Text(hasQuery ? "Try another channel name, a person's name or @username."
                          : "Channels and direct messages you join appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct QuickSwitcherFooter: View {
    var body: some View {
        HStack(spacing: 16) {
            hint(["arrow.up", "arrow.down"], "Navigate")
            hint(["return"], "Open")
            hint(nil, "Close", key: "esc")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func hint(_ symbols: [String]?, _ label: LocalizedStringKey, key: String? = nil) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                if let symbols {
                    ForEach(symbols, id: \.self) { keycap(Image(systemName: $0).font(.system(size: 9, weight: .bold))) }
                }
                if let key { keycap(Text(verbatim: key).font(.system(size: 10, weight: .medium))) }
            }
            Text(label)
        }
    }

    private func keycap(_ content: some View) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

/// Records the window's first responder when the switcher opens and gives it back
/// when it closes, if that view is still in the window.
private struct ResponderRestorer: NSViewRepresentable {
    let isPresented: Bool

    final class Coordinator {
        var wasPresented = false
        weak var previous: NSResponder?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented != coordinator.wasPresented else { return }
        coordinator.wasPresented = isPresented
        guard let window = view.window else { return }
        if isPresented {
            let responder = window.firstResponder
            coordinator.previous = (responder as? NSTextView)?.isFieldEditor == true ? nil : responder
        } else {
            let previous = coordinator.previous
            coordinator.previous = nil
            Task { @MainActor [weak window] in
                // Only when nothing else took focus since (such as a reopened palette).
                guard let window, let previous, (previous as? NSView)?.window === window,
                      window.firstResponder === window else { return }
                window.makeFirstResponder(previous)
            }
        }
    }
}
