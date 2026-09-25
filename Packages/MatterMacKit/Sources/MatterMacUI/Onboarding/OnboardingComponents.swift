import SwiftUI
import AppKit

/// Shared pieces of the sign-in screens: the centred glass card, the header, the
/// step indicator, large fields with a leading symbol, notices and the server chip.
enum OnboardingStyle {
    /// Width of the card's content column.
    static let columnWidth: CGFloat = 400
    static let fieldHeight: CGFloat = 40
    static let fieldRadius: CGFloat = 12
    /// Supporting text. Full `.secondary` fails contrast on the glass card.
    static let supporting = Color.primary.opacity(0.74)
}

/// The three steps of adding an account: enter the address, confirm the final
/// origin, sign in.
enum OnboardingStep: Int, CaseIterable {
    case server, confirm, signIn

    var title: String {
        switch self {
        case .server: String(localized: "Server")
        case .confirm: String(localized: "Confirm")
        case .signIn: String(localized: "Sign In")
        }
    }
}

/// Centres a glass card in the window and scrolls when the window is too short.
struct OnboardingCardLayout<Content: View>: View {
    var width: CGFloat = OnboardingStyle.columnWidth
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    /// Keeps text on the card legible over any backdrop colour.
    private var cardTint: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor).opacity(0.3) : Color.white.opacity(0.2)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                        .frame(width: width)
                        .padding(.horizontal, 40)
                        .padding(.top, 28)
                        .padding(.bottom, 32)
                        .glassSurface(cornerRadius: 32, tint: cardTint)
                        .shadow(color: .black.opacity(0.10), radius: 30, y: 12)
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// App icon, large title and a one-line subtitle, as in Apple's setup screens.
struct OnboardingHeader: View {
    let title: String
    let subtitle: String?
    var iconSize: CGFloat = 76

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.title3)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Compact "1 Server — 2 Confirm — 3 Sign In" progress, read as one element.
struct OnboardingStepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                if step != .server {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.18)))
                        .frame(width: 22, height: 2)
                }
                HStack(spacing: 5) {
                    badge(step)
                    Text(verbatim: step.title)
                        .font(.caption.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Color.primary : OnboardingStyle.supporting)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)"))
        .accessibilityIdentifier("onboardingStep")
    }

    @ViewBuilder private func badge(_ step: OnboardingStep) -> some View {
        ZStack {
            if step.rawValue < current.rawValue {
                Circle().fill(.tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
            } else if step == current {
                Circle().fill(.tint)
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OnboardingStyle.supporting)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A large rounded field with a leading symbol and a focus ring. The wrapped
/// control keeps its own accessibility label; the symbol is decorative.
struct OnboardingField<Field: View>: View {
    let systemImage: String
    var isFocused = false
    var isInvalid = false
    var focus: () -> Void = {}
    @ViewBuilder var field: Field

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OnboardingStyle.fieldRadius, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isInvalid ? AnyShapeStyle(Color.red)
                                 : isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(OnboardingStyle.supporting))
                .frame(width: 22)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(.title3)
                .focusEffectDisabled()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: OnboardingStyle.fieldHeight, maxHeight: OnboardingStyle.fieldHeight)
        .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
        .overlay(shape.strokeBorder(border, lineWidth: isFocused || isInvalid ? 1.5 : 1))
        .overlay {
            if isFocused {
                shape.inset(by: -3).strokeBorder(isInvalid ? AnyShapeStyle(Color.red.opacity(0.25))
                                                 : AnyShapeStyle(.tint.opacity(0.3)), lineWidth: 3)
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: focus)
    }

    private var border: AnyShapeStyle {
        if isInvalid { return AnyShapeStyle(Color.red.opacity(0.8)) }
        return isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.14))
    }
}

/// The confirmed server as a pill, with an optional "Change" action.
struct OnboardingServerChip: View {
    let origin: String
    let isSecure: Bool
    var change: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSecure ? "lock.fill" : "lock.open.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSecure ? OnboardingStyle.supporting : Color.orange)
                .accessibilityLabel(isSecure ? Text("Encrypted connection") : Text("Unencrypted connection"))
            Text(verbatim: origin)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("loginOrigin")
            if let change {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 14)
                    .accessibilityHidden(true)
                Button("Change", action: change)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHint(Text("Enter a different server address"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, change == nil ? 12 : 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }
}

/// An inline callout: validation, errors, explanations and sign-out results.
struct OnboardingNotice: View {
    enum Tone { case info, success, warning, error }
    let tone: Tone
    let systemImage: String
    let message: String
    /// Accessibility identifier of the message text (tests find it by this).
    var identifier: String?
    var actionTitle: String?
    var action: () -> Void = {}
    var actionDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                messageText
                    .font(.callout)
                    // Primary text keeps contrast; the symbol and tint carry the tone.
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .glassButtonStyle()
                    .controlSize(.regular)
                    .disabled(actionDisabled)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.11)))
    }

    @ViewBuilder private var messageText: some View {
        if let identifier {
            Text(verbatim: message).accessibilityIdentifier(identifier)
        } else {
            Text(verbatim: message)
        }
    }

    private var color: AnyShapeStyle {
        switch tone {
        case .info: AnyShapeStyle(.tint)
        case .success: AnyShapeStyle(Color.green)
        case .warning: AnyShapeStyle(Color.orange)
        case .error: AnyShapeStyle(Color.red)
        }
    }
}

/// Wide, prominent capsule button; the label may switch to progress.
struct OnboardingPrimaryButtonLabel: View {
    let title: String
    var progressTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            if let progressTitle {
                ProgressView().controlSize(.small)
                Text(verbatim: progressTitle)
            } else {
                Text(verbatim: title)
            }
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// The onboarding call to action: prominent glass capsule, extra large.
    func onboardingPrimaryButton() -> some View {
        glassButtonStyle(prominent: true)
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
    }

    /// Secondary onboarding actions next to the primary one.
    func onboardingSecondaryButton() -> some View {
        glassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
            // Neutral glass even when a theme tints the screens.
            .tint(nil)
    }
}
