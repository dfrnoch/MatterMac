import SwiftUI
import MatterMacModels
import MatterMacCore

/// Presents one directory sheet. Results live only while the sheet is open.
struct DirectorySheetView: View {
    let session: SessionViewModel
    let sheet: DirectorySheet

    var body: some View {
        switch sheet {
        case .browseChannels: BrowseChannelsView(session: session)
        case .createChannel: CreateChannelView(session: session)
        case .newMessage: PeoplePickerView(session: session, mode: .newMessage)
        case .addMembers(let channel): PeoplePickerView(session: session, mode: .addMembers(channel))
        }
    }
}

// MARK: - Browse Channels

/// Public (or archived) channels of the selected team, searched on the server.
/// At most `maximumItems` results are kept while the sheet is open.
struct BrowseChannelsView: View {
    let session: SessionViewModel
    static let maximumItems = 500
    @State private var query = ""
    @State private var archived = false
    @State private var items: [BrowseChannelItem] = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var state: LoadState = .loading
    @State private var loadTask: Task<Void, Never>?
    @State private var selection: ChannelID?
    @State private var busy: ChannelID?
    @State private var actionError: String?
    @FocusState private var searchFocused: Bool

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse Channels").font(.title3.weight(.semibold))
                Spacer()
                Button("New Channel…") { session.directorySheet = .createChannel }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search channels", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search channels")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                if session.sidebar?.canBrowseArchivedChannels == true {
                    Picker("Show", selection: $archived) {
                        Text("Channels").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Show archived channels")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            content
            Divider()
            HStack {
                if let actionError {
                    Text(verbatim: actionError).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Done") { session.directorySheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 540)
        .onAppear {
            searchFocused = true
            reload(debounce: false)
        }
        .onChange(of: query) { reload(debounce: true) }
        .onChange(of: archived) { reload(debounce: false) }
        .onDisappear { loadTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading where items.isEmpty:
            ProgressView("Loading channels…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(verbatim: message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { reload(debounce: false) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if items.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(items) { item in
                        BrowseChannelRow(item: item, isBusy: busy == item.channelID) { activate(item) }
                            .tag(item.channelID)
                    }
                    if hasMore {
                        Button("Load More") { loadMore() }
                            .buttonStyle(.link)
                            .disabled(state == .loading)
                    } else if items.count >= Self.maximumItems {
                        Text("Showing the first \(items.count) channels. Search to find others.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: ChannelID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let item = items.first(where: { $0.channelID == id }) { activate(item) }
                }
            }
        }
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "No channels match your search.") }
        return archived ? String(localized: "There are no archived channels you can view.")
            : String(localized: "There are no public channels to browse on this team.")
    }

    private func reload(debounce: Bool) {
        loadTask?.cancel()
        let term = query
        let archived = archived
        loadTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            state = .loading
            do throws(UserFacingError) {
                let result = try await session.browseChannels(term: term, archived: archived, page: 0)
                guard !Task.isCancelled else { return }
                items = Array(result.items.prefix(Self.maximumItems))
                hasMore = result.hasMore && items.count < Self.maximumItems
                page = 0
                state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                items = []
                state = .failed(UserFacingErrorText.describe(error))
            }
        }
    }

    private func loadMore() {
        guard hasMore, state != .loading else { return }
        let term = query
        let archived = archived
        let next = page + 1
        state = .loading
        loadTask = Task {
            do throws(UserFacingError) {
                let result = try await session.browseChannels(term: term, archived: archived, page: next)
                guard !Task.isCancelled else { return }
                let known = Set(items.map(\.channelID))
                items.append(contentsOf: result.items.filter { !known.contains($0.channelID) }
                    .prefix(max(0, Self.maximumItems - items.count)))
                page = next
                hasMore = result.hasMore && items.count < Self.maximumItems
                state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                state = .loaded
                actionError = UserFacingErrorText.describe(error)
            }
        }
    }

    private func activate(_ item: BrowseChannelItem) {
        guard busy == nil, item.isMember || !item.isArchived else { return }
        busy = item.channelID
        actionError = nil
        Task {
            defer { busy = nil }
            do throws(UserFacingError) {
                try await session.joinAndOpen(item.channelID)
                session.directorySheet = nil
            } catch {
                actionError = UserFacingErrorText.describe(error)
            }
        }
    }
}

struct BrowseChannelRow: View {
    let item: BrowseChannelItem
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isArchived ? "archivebox" : (item.type == .private ? "lock" : "number"))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.displayName).fontWeight(.medium).lineLimit(1)
                if !item.purpose.isEmpty {
                    Text(verbatim: item.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let count = item.memberCount {
                        Label("\(count) members", systemImage: "person.2").labelStyle(.titleAndIcon)
                    }
                    if item.isMember { Label("Joined", systemImage: "checkmark").labelStyle(.titleAndIcon) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if item.isMember {
                Button("View", action: action)
            } else if !item.isArchived {
                Button("Join", action: action)
            } else {
                Text("Archived").font(.caption).foregroundStyle(.secondary)
                    .help("Archived channels can’t be joined.")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Create Channel

struct CreateChannelView: View {
    let session: SessionViewModel
    @State private var displayName = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var purpose = ""
    @State private var isPrivate = false
    @State private var isWorking = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Channel").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $displayName, prompt: Text("e.g. Release planning"))
                    .focused($nameFocused)
                    .onChange(of: displayName) { if !nameEdited { name = ChannelNameRules.slug(from: displayName) } }
                VStack(alignment: .leading, spacing: 3) {
                    TextField("URL", text: Binding(get: { name }, set: {
                        nameEdited = true
                        name = String($0.lowercased().prefix(ChannelNameRules.maximumLength))
                    }))
                    .font(.body.monospaced())
                    if let prefix = urlPrefix {
                        Text(verbatim: prefix + (name.isEmpty ? "…" : name))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if !name.isEmpty, let problem = ChannelNameRules.problem(with: name) {
                        Text(Self.describe(problem)).font(.caption).foregroundStyle(.red)
                    }
                }
                TextField("Purpose", text: $purpose, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                if purpose.count > ChannelNameRules.maximumPurposeCharacters {
                    Text("The purpose can be at most \(ChannelNameRules.maximumPurposeCharacters) characters.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("Visibility", selection: $isPrivate) {
                    Text("Public — anyone on the team can find and join").tag(false)
                    Text("Private — only people who are added").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            if let failure {
                Text(verbatim: failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.directorySheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create Channel") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { nameFocused = true }
    }

    private var urlPrefix: String? {
        guard let sidebar = session.sidebar, let team = sidebar.teams.first(where: { $0.id == sidebar.selectedTeam })
        else { return nil }
        return session.slot.endpoint.url(path: [team.name, "channels"]).absoluteString + "/"
    }

    private var canCreate: Bool {
        !isWorking && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.trimmingCharacters(in: .whitespacesAndNewlines).count <= ChannelNameRules.maximumDisplayNameCharacters
            && ChannelNameRules.problem(with: name) == nil
            && purpose.count <= ChannelNameRules.maximumPurposeCharacters
    }

    private func create() {
        guard canCreate else { return }
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do throws(ChannelCreationError) {
                try await session.createChannel(displayName: displayName, name: name, purpose: purpose, isPrivate: isPrivate)
                session.directorySheet = nil
            } catch {
                failure = Self.describe(error)
            }
        }
    }

    static func describe(_ problem: ChannelNameRules.Problem) -> String {
        switch problem {
        case .tooShort: String(localized: "The URL must be at least \(ChannelNameRules.minimumLength) characters.")
        case .tooLong: String(localized: "The URL can be at most \(ChannelNameRules.maximumLength) characters.")
        case .invalidCharacters: String(localized: "Use only lowercase letters, numbers, hyphens and underscores.")
        case .invalidStart: String(localized: "The URL must start with a letter or number.")
        case .reserved: String(localized: "That URL is reserved for direct and group messages.")
        }
    }

    static func describe(_ error: ChannelCreationError) -> String {
        switch error {
        case .invalidName(let problem): describe(problem)
        case .missingDisplayName: String(localized: "Enter a channel name.")
        case .displayNameTooLong:
            String(localized: "The name can be at most \(ChannelNameRules.maximumDisplayNameCharacters) characters.")
        case .purposeTooLong:
            String(localized: "The purpose can be at most \(ChannelNameRules.maximumPurposeCharacters) characters.")
        case .nameTaken: String(localized: "A channel with this URL already exists on the team. Choose another URL.")
        case .nameUsedByArchivedChannel:
            String(localized: "An archived channel uses this URL. Choose another URL or ask an administrator to restore it.")
        case .channelLimitReached: String(localized: "This team has reached the server’s channel limit.")
        case .permissionDenied(let isPrivate):
            isPrivate ? String(localized: "You don’t have permission to create private channels on this team.")
                : String(localized: "You don’t have permission to create public channels on this team.")
        case .failed(let error): UserFacingErrorText.describe(error)
        }
    }
}

// MARK: - People picker (new message, add members)

struct PeoplePickerView: View {
    enum Mode: Equatable {
        case newMessage
        case addMembers(ChannelID)
    }

    let session: SessionViewModel
    let mode: Mode
    @State private var query = ""
    @State private var results: [UserPickerItem] = []
    @State private var selected: [UserPickerItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var highlighted: UserID?
    @FocusState private var searchFocused: Bool

    private var limit: Int {
        mode == .newMessage ? ServerSession.maximumGroupMessageMembers : ServerSession.maximumMembersPerAdd
    }

    private var excludedChannel: ChannelID? {
        if case .addMembers(let channel) = mode { return channel }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            if !selected.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(selected) { person in
                            HStack(spacing: 4) {
                                Text(verbatim: person.displayName).lineLimit(1)
                                Button {
                                    selected.removeAll { $0.userID == person.userID }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(person.displayName)")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(addHighlighted)
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                    .accessibilityLabel("Search people")
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            List(selection: $highlighted) {
                if results.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
                }
                ForEach(results) { person in
                    PersonRow(session: session, person: person,
                              isSelected: selected.contains { $0.userID == person.userID })
                        .tag(person.userID)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(person) }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if let failure {
                Text(verbatim: failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.directorySheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
        .onAppear {
            searchFocused = true
            if mode == .newMessage {
                Task {
                    let recent = await session.recentDirectMessagePartners()
                    if query.isEmpty { results = recent; highlighted = recent.first?.userID }
                }
            }
        }
        .onChange(of: query) { schedule() }
        .onDisappear { searchTask?.cancel() }
    }

    private var title: String {
        switch mode {
        case .newMessage: return String(localized: "New Message")
        case .addMembers(let channel):
            let name = session.sidebar?.sections.lazy.flatMap(\.rows).first { $0.channelID == channel }?.displayName
            return name.map { String(localized: "Add Members to \($0)") } ?? String(localized: "Add Members")
        }
    }

    private var hint: String {
        switch mode {
        case .newMessage:
            String(localized: "Choose one person for a direct message, or up to \(limit) for a group message.")
        case .addMembers:
            String(localized: "Up to \(limit) people at a time. Adding members requires permission on this channel.")
        }
    }

    private var emptyText: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Type a name or username to search.")
        }
        return isSearching ? String(localized: "Searching…") : String(localized: "No matching people.")
    }

    private var confirmTitle: String {
        switch mode {
        case .newMessage: selected.count > 1 ? String(localized: "Start Group Message") : String(localized: "Go")
        case .addMembers: String(localized: "Add")
        }
    }

    private func schedule() {
        searchTask?.cancel()
        let term = query
        let channel = excludedChannel
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            isSearching = false
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { if !Task.isCancelled { isSearching = false } }
            do throws(UserFacingError) {
                let found = try await session.searchUsers(term, notInChannel: channel)
                guard !Task.isCancelled else { return }
                results = found
                highlighted = found.first?.userID
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                failure = UserFacingErrorText.describe(error)
            }
        }
    }

    private func toggle(_ person: UserPickerItem) {
        if let index = selected.firstIndex(where: { $0.userID == person.userID }) {
            selected.remove(at: index)
        } else if selected.count < limit {
            selected.append(person)
            failure = nil
        } else {
            failure = String(localized: "You can choose up to \(limit) people.")
        }
    }

    private func addHighlighted() {
        guard let id = highlighted ?? results.first?.userID, let person = results.first(where: { $0.userID == id }) else {
            if !selected.isEmpty { confirm() }
            return
        }
        if !selected.contains(where: { $0.userID == id }) { toggle(person) }
        query = ""
    }

    private func moveHighlight(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.userID == highlighted } ?? -1
        highlighted = results[max(0, min(results.count - 1, index + delta))].userID
    }

    private func confirm() {
        guard !selected.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        let users = selected.map(\.userID)
        Task {
            defer { isWorking = false }
            do throws(UserFacingError) {
                switch mode {
                case .newMessage: try await session.openConversation(with: users)
                case .addMembers(let channel): try await session.addMembers(users, to: channel)
                }
                session.directorySheet = nil
            } catch {
                failure = UserFacingErrorText.describe(error)
            }
        }
    }
}

struct PersonRow: View {
    let session: SessionViewModel
    let person: UserPickerItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProfileAvatar(session: session, userID: person.userID, revision: person.avatarRevision,
                          name: person.displayName, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: person.displayName).lineLimit(1)
                Text(verbatim: "@" + person.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if person.isBot {
                Text("BOT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
