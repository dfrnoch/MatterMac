import Foundation
import MatterMacUpdateSupport

// MatterMac's update installer (decision 0034). An XPC service embedded in the app
// at Contents/XPCServices. Unlike the app it is not sandboxed: replacing the app
// bundle in /Applications needs that. It accepts connections only from MatterMac
// signed by the same team, checks every update itself (whatever the app claims)
// and never installs anything that is not a newer, correctly signed MatterMac.

/// What the installed copy (and the connecting app) must be.
let teamRequirement = """
    identifier "\(UpdateSupport.bundleIdentifier)" and anchor apple generic \
    and certificate leaf[subject.OU] = "\(UpdateSupport.teamIdentifier)"
    """

#if DEBUG
// Development builds are signed with Apple Development and not notarized.
let updateRequirement = teamRequirement
#else
let updateRequirement = UpdateSupport.updateRequirement
#endif

final class Installer: NSObject, UpdateInstalling {
    func installUpdate(fromArchive archive: FileHandle, sha256: String, replacingAppAtPath installedPath: String,
                       relaunchAfterProcess pid: Int32, arguments: [String],
                       withReply reply: @escaping @Sendable (String?) -> Void) {
        let installed = URL(fileURLWithPath: installedPath).standardizedFileURL
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatterMacUpdate-\(UUID().uuidString)", isDirectory: true)
        do throws(UpdateSupport.Failure) {
            guard installed.pathExtension == "app" else { throw .notAnApplication }
            try UpdateSupport.verifySignature(of: installed, requirement: teamRequirement)
            try UpdateSupport.installArchive(from: archive, expectedSHA256: sha256, replacing: installed,
                                             requirement: updateRequirement, workDirectory: work)
            try UpdateSupport.scheduleRelaunch(of: installed, after: pid, arguments: arguments)
            reply(nil)
        } catch {
            reply(error.description)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only MatterMac itself may ask for an install.
        connection.setCodeSigningRequirement(teamRequirement)
        connection.exportedInterface = NSXPCInterface(with: (any UpdateInstalling).self)
        connection.exportedObject = Installer()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
