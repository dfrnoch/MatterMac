import AppKit
import UniformTypeIdentifiers
import SwiftUI
import MatterMacModels
import MatterMacCore
import MattermostAPI

struct ProfileSettingsView: View {
    let session: SessionViewModel
    @State private var original: User?
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var nickname = ""
    @State private var position = ""
    @State private var picturePanel: NSOpenPanel?
    @State private var picture: Data?
    @State private var picturePreview: NSImage?
    @State private var change = ServerChangeState()

    var body: some View {
        Form {
            if let user = original {
                Section {
                    HStack {
                        if let picturePreview {
                            Image(nsImage: picturePreview).resizable().scaledToFill()
                                .frame(width: 64, height: 64).clipShape(Circle())
                        } else {
                            ProfileAvatar(session: session, userID: user.id, revision: user.lastPictureUpdate.milliseconds,
                                          name: user.username, size: 64)
                        }
                        Button("Choose Picture…", action: choosePicture)
                        if let picture {
                            Button("Upload Picture") {
                                change.run {
                                    let user = try await session.session.updateProfilePicture(picture)
                                    guard session.canChangeServerSettings, !Task.isCancelled else { return }
                                    original = user
                                    self.picture = nil
                                    picturePreview = nil
                                }
                            }
                            Button("Cancel") { self.picture = nil; picturePreview = nil }
                        } else if user.lastPictureUpdate.milliseconds > 0 {
                            Button("Remove Picture") {
                                change.run {
                                    let user = try await session.session.updateProfilePicture(nil)
                                    guard session.canChangeServerSettings, !Task.isCancelled else { return }
                                    original = user
                                }
                            }
                        }
                    }
                    LabeledContent("Username", value: "@" + user.username)
                    LabeledContent("Email", value: user.email)
                    Text("Change your username and email in your server’s account settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    field("First name", value: $firstName, limit: UserProfilePatch.firstNameLimit)
                    field("Last name", value: $lastName, limit: UserProfilePatch.lastNameLimit)
                    field("Nickname", value: $nickname, limit: UserProfilePatch.nicknameLimit)
                    field("Position", value: $position, limit: UserProfilePatch.positionLimit)
                    if !user.authService.isEmpty && user.authService != "email" {
                        Text("Your sign-in provider may manage some fields. The server decides which changes are allowed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save Profile") {
                        let patch = patch(user)
                        change.run {
                            let user = try await session.session.updateProfile(patch)
                            guard session.canChangeServerSettings, !Task.isCancelled else { return }
                            adopt(user)
                        }
                    }
                    .disabled(patch(user).isEmpty || patch(user).fieldOverLimit != nil || !session.canChangeServerSettings)
                    .accessibilityIdentifier("saveProfile")
                } header: { ServerSectionHeader(session: session) }
                .disabled(change.isSaving)
                ServerChangeStatus(state: change)
            } else {
                if let error = change.error {
                    Text(error).foregroundStyle(.red)
                } else { Text("Loading profile…").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: session.isDetached) {
            guard session.isDetached else { return }
            change.cancel()
            picturePanel?.cancel(nil)
            picturePanel = nil
            original = nil
            firstName = ""
            lastName = ""
            nickname = ""
            position = ""
            picture = nil
            picturePreview = nil
            change.error = UserFacingErrorText.describe(.authenticationRequired)
        }
        .onDisappear {
            change.cancel()
            picturePanel?.cancel(nil)
            picturePanel = nil
            picture = nil
            picturePreview = nil
        }
        .task(id: session.slot.id) {
            if let profile = await session.profile(for: session.slot.user.id) { adopt(profile.user) }
            else { change.error = UserFacingErrorText.describe(.notFoundOrInaccessible) }
        }
    }

    private func choosePicture() {
        guard !change.isSaving, picturePanel == nil, session.canChangeServerSettings else { return }
        let panel = NSOpenPanel()
        picturePanel = panel
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            picturePanel = nil
            guard response == .OK, let url = panel.url, session.canChangeServerSettings else { return }
            change.run {
                let data = try await ProfilePicture.prepare(url)
                guard !Task.isCancelled, session.canChangeServerSettings else { return }
                picture = data
                picturePreview = NSImage(data: data)
            }
        }
    }

    private func field(_ label: LocalizedStringKey, value: Binding<String>, limit: Int) -> some View {
        TextField(label, text: Binding(get: { value.wrappedValue }, set: { newValue in
            // Refuse excess input; never silently truncate a profile edit.
            if newValue.unicodeScalars.count <= limit { value.wrappedValue = newValue }
        }))
    }

    private func patch(_ user: User) -> UserProfilePatch {
        UserProfilePatch(firstName: firstName == user.firstName ? nil : firstName,
                         lastName: lastName == user.lastName ? nil : lastName,
                         nickname: nickname == user.nickname ? nil : nickname,
                         position: position == user.position ? nil : position)
    }

    private func adopt(_ user: User) {
        original = user
        firstName = user.firstName
        lastName = user.lastName
        nickname = user.nickname
        position = user.position
    }
}

@MainActor
enum ProfileEditSheet {
    private static weak var current: NSWindow?
    private static weak var owner: SessionViewModel?

    static func close(for session: SessionViewModel) {
        guard owner === session, let sheet = current else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        sheet.contentViewController = nil
        current = nil
        owner = nil
    }

    @discardableResult
    static func present(session: SessionViewModel, on host: NSWindow? = nil) -> NSWindow? {
        guard session.canChangeServerSettings, current == nil, let host = host ?? NSApp.keyWindow ?? NSApp.mainWindow, host.attachedSheet == nil else { return nil }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 490), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isRestorable = false
        sheet.isReleasedWhenClosed = false
        let content = VStack {
            ProfileSettingsView(session: session)
            Button("Done") { [weak host, weak sheet] in
                guard let sheet else { return }
                host?.endSheet(sheet)
            }.padding(.bottom)
        }.frame(width: 520, height: 490)
        .onChange(of: session.isDetached) { [weak host, weak sheet] in
            guard session.isDetached, let sheet else { return }
            host?.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(rootView: content)
        current = sheet
        owner = session
        host.beginSheet(sheet) { [weak sheet] _ in
            if current === sheet { current = nil; owner = nil }
        }
        return sheet
    }
}
