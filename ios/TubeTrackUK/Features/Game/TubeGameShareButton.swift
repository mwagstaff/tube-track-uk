import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Concrete image data, kept alive by the activity controller for the entire share.
final class TubeGameShareItem: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.png.identifier }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

/// Present from the visible controller in the button's window, including when
/// the game itself is a full-screen presentation or its timeline has stopped.
struct TubeGameShareButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let makeItem: @MainActor () -> TubeGameShareItem?
    let onFailure: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "game.shareScore"
        button.addAction(UIAction { [weak button, coordinator = context.coordinator] _ in
            guard let button else { return }
            coordinator.share(from: button)
        }, for: .touchUpInside)
        configure(button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        configure(button)
    }

    private func configure(_ button: UIButton) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Share score"
        configuration.image = UIImage(systemName: "square.and.arrow.up")
        configuration.imagePadding = 10
        configuration.baseForegroundColor = colorScheme == .dark ? .white : .black
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
    }

    @MainActor final class Coordinator {
        var parent: TubeGameShareButton
        init(parent: TubeGameShareButton) { self.parent = parent }

        func share(from button: UIButton) {
            guard let window = button.window,
                  var presenter = window.rootViewController else {
                parent.onFailure()
                return
            }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            // Ignore rapid repeat taps while the already-visible sheet is opening.
            guard !(presenter is UIActivityViewController) else { return }
            guard presenter.viewIfLoaded?.window === window else {
                parent.onFailure()
                return
            }
            guard let item = parent.makeItem() else {
                parent.onFailure()
                return
            }
            let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = button
            activity.popoverPresentationController?.sourceRect = button.bounds
            activity.completionWithItemsHandler = { [onFailure = parent.onFailure] _, _, _, error in
                if error != nil { onFailure() }
            }
            presenter.present(activity, animated: true)
        }
    }
}
