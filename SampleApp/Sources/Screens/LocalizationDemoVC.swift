import SwiftUI
import UIKit

/// Exercises every way an app usually puts localized text on screen, plus a
/// pushed screen and a modal sheet, so Voly's language override, UI refresh
/// and navigation actions each have something real to act on.
final class LocalizationDemoVC: UIViewController {
    private let nameField = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = NSLocalizedString("loc.title", comment: "")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("loc.button.present", comment: ""),
            style: .plain, target: self, action: #selector(presentSheetTapped)
        )

        let greeting = UILabel()
        greeting.font = .preferredFont(forTextStyle: .title2)
        greeting.text = NSLocalizedString("loc.greeting", comment: "")
        greeting.accessibilityIdentifier = "loc.greeting"

        let subtitle = UILabel()
        subtitle.numberOfLines = 0
        subtitle.textColor = .secondaryLabel
        subtitle.text = NSLocalizedString("loc.subtitle", comment: "")
        subtitle.accessibilityIdentifier = "loc.subtitle"

        // Foundation's newer lookup path.
        let modern = UILabel()
        modern.numberOfLines = 0
        modern.text = String(localized: "loc.modern")
        modern.accessibilityIdentifier = "loc.modern"

        // Built with a format argument / plural rule: can't be mapped back to
        // a key once displayed, so an in-place refresh must leave these alone.
        let formatted = UILabel()
        formatted.text = String(format: NSLocalizedString("loc.items.format", comment: ""), 3)
        formatted.accessibilityIdentifier = "loc.items.format"

        let plural = UILabel()
        plural.text = String.localizedStringWithFormat(NSLocalizedString("loc.files.count", comment: ""), 2)
        plural.accessibilityIdentifier = "loc.files.count"

        nameField.borderStyle = .roundedRect
        nameField.placeholder = NSLocalizedString("loc.placeholder.name", comment: "")
        nameField.accessibilityIdentifier = "loc.name"
        // Stands in for something the user typed; a refresh must not touch it.
        nameField.text = ProcessInfo.processInfo.environment["VOLY_SAMPLE_NAME"]

        let segments = UISegmentedControl(items: [
            NSLocalizedString("loc.segment.first", comment: ""),
            NSLocalizedString("loc.segment.second", comment: ""),
        ])
        segments.selectedSegmentIndex = 1

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("loc.button.details", comment: "")
        let details = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.showDetails(animated: true)
        })
        details.accessibilityIdentifier = "loc.details"

        let swiftUI = UIHostingController(rootView: LocalizedSwiftUIRow())
        addChild(swiftUI)
        swiftUI.view.backgroundColor = .clear

        let stack = UIStackView(arrangedSubviews: [
            greeting, subtitle, modern, formatted, plural, nameField, segments, details, swiftUI.view,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        swiftUI.didMove(toParent: self)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func showDetails(animated: Bool) {
        navigationController?.pushViewController(LocalizationDetailVC(), animated: animated)
    }

    @objc private func presentSheetTapped() {
        presentSheet(animated: true, pushingMore: false)
    }

    func presentSheet(animated: Bool, pushingMore: Bool) {
        let sheet = LocalizationSheetVC()
        let navigation = UINavigationController(rootViewController: sheet)
        if pushingMore {
            navigation.pushViewController(LocalizationDetailVC(), animated: false)
        }
        (navigationController ?? self).present(navigation, animated: animated)
    }
}

final class LocalizationDetailVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = NSLocalizedString("loc.detail.title", comment: "")
        let body = UILabel()
        body.numberOfLines = 0
        body.text = NSLocalizedString("loc.detail.body", comment: "")
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}

final class LocalizationSheetVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        title = NSLocalizedString("loc.sheet.title", comment: "")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("loc.sheet.close", comment: ""),
            style: .done, target: self, action: #selector(close)
        )
        let body = UILabel()
        body.numberOfLines = 0
        body.text = NSLocalizedString("loc.sheet.body", comment: "")
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

private struct LocalizedSwiftUIRow: View {
    var body: some View {
        Text("loc.swiftui.greeting")
            .font(.callout)
            .accessibilityIdentifier("loc.swiftui")
    }
}

/// A SwiftUI `NavigationStack` that starts two levels deep, for checking how
/// far UIKit-level navigation commands reach into SwiftUI.
struct SwiftUIStackDemo: View {
    @State private var path: [Int]

    init(depth: Int) {
        _path = State(initialValue: Array(1...max(depth, 1)).dropLast().map { $0 })
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink("Level 1", value: 1)
            }
            .navigationTitle("SwiftUI Stack")
            .navigationDestination(for: Int.self) { level in
                List {
                    Text("Level \(level)")
                    Text("loc.swiftui.greeting")
                    NavigationLink("Level \(level + 1)", value: level + 1)
                }
                .navigationTitle("Level \(level)")
            }
        }
    }
}
