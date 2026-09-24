import Foundation
import MatterMacCore

/// Localized, content-free explanations for typed errors. Never shows server message
/// bodies (which can echo user content).
enum UserFacingErrorText {
    static func describe(_ error: UserFacingError) -> String {
        switch error {
        case .offline:
            String(localized: "You appear to be offline.")
        case .timedOut:
            String(localized: "The server took too long to respond.")
        case .serverUnreachable:
            String(localized: "The server couldn’t be reached.")
        case .tlsFailure:
            String(localized: "A secure connection couldn’t be established. The server’s certificate may not be trusted by this Mac.")
        case .authenticationRequired:
            String(localized: "Your session has ended. Sign in again.")
        case .invalidCredentials:
            String(localized: "The sign-in details were not accepted.")
        case .mfaRequired:
            String(localized: "A multi-factor authentication code is required.")
        case .invalidMFACode:
            String(localized: "The authentication code was not accepted.")
        case .accountLocked:
            String(localized: "The account is temporarily locked.")
        case .loginMethodDisabled:
            String(localized: "This sign-in method is disabled on the server.")
        case .permissionDenied:
            String(localized: "You don’t have permission to do that.")
        case .notFoundOrInaccessible:
            String(localized: "It’s no longer available, or you don’t have access to it.")
        case .rateLimited(let seconds):
            if let seconds {
                String(localized: "The server is limiting requests. Try again in \(seconds) seconds.")
            } else {
                String(localized: "The server is limiting requests. Try again shortly.")
            }
        case .payloadTooLarge(let limit):
            limit > 0
                ? String(localized: "That’s larger than the server allows (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))).")
                : String(localized: "That’s larger than the server allows.")
        case .messageTooLong(let limit):
            String(localized: "The message is longer than the server allows (\(limit) characters).")
        case .commandNotFound:
            String(localized: "The server doesn’t recognize that command. To send a message that begins with “/”, start it with a space.")
        case .commandOutcomeUnknown:
            String(localized: "The command was sent, but the server’s response was lost. It may already have run; check before trying again.")
        case .unsupportedCapability(let what):
            String(localized: "This server doesn’t support \(what).")
        case .malformedServerData:
            String(localized: "The server sent data MatterMac couldn’t read.")
        case .serverError(let status):
            String(localized: "The server reported an error (\(status)).")
        case .budgetExceeded(let kind):
            switch kind {
            case .unsentText:
                String(localized: "MatterMac’s memory limit for unsent text is reached. Send, copy, or discard existing drafts first.")
            case .pendingOperations:
                String(localized: "Too many messages are waiting to send. Wait for them or discard some first.")
            case .pastedImages:
                String(localized: "The memory limit for pasted images is reached. Attach the image as a file instead.")
            case .attachmentCount:
                String(localized: "The limit for this item was reached.")
            case .attachmentSize:
                String(localized: "The file is larger than allowed.")
            }
        case .cancelled:
            String(localized: "Cancelled.")
        case .fileUnavailable:
            String(localized: "The file changed or is no longer available.")
        case .unknown:
            String(localized: "Something went wrong.")
        }
    }
}
