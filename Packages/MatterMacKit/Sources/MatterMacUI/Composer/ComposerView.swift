public import SwiftUI

/// SwiftUI bridge for a host-owned `ComposerViewController`.
///
/// The host keeps the controller (one per conversation pane) so it can call
/// `load(draft:)`, `currentDraft()`, `clear()`, and `focus()` directly; this view
/// only embeds it and sizes itself to the composer's preferred height. Embed a
/// given controller in at most one place at a time. The controller's
/// `onPreferredHeightChange` is owned by this bridge while it is embedded.
public struct ComposerView: View {
    private let controller: ComposerViewController
    @State private var height: CGFloat

    public init(controller: ComposerViewController) {
        self.controller = controller
        _height = State(initialValue: max(controller.preferredHeight, 40))
    }

    public var body: some View {
        ComposerControllerRepresentable(controller: controller, height: $height)
            .frame(height: height)
    }
}

struct ComposerControllerRepresentable: NSViewControllerRepresentable {
    let controller: ComposerViewController
    @Binding var height: CGFloat

    func makeNSViewController(context: Context) -> ComposerViewController {
        let binding = $height
        controller.onPreferredHeightChange = { newHeight in
            if binding.wrappedValue != newHeight { binding.wrappedValue = newHeight }
        }
        controller.loadViewIfNeeded()
        if controller.preferredHeight > 0, controller.preferredHeight != height {
            let initial = controller.preferredHeight
            Task { @MainActor in binding.wrappedValue = initial }
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: ComposerViewController, context: Context) {}

    static func dismantleNSViewController(_ nsViewController: ComposerViewController, coordinator: ()) {
        nsViewController.onPreferredHeightChange = nil
        nsViewController.dismissTransientUI()
    }
}
