import SwiftUI
import UIKit

final class SampleRootViewController: UIViewController {
    private let tabs = UITabBarController()
    private let localization = LocalizationDemoVC()
    private var didApplyRoute = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tabs.viewControllers = [
            nav(AutoLayoutDemoVC(), title: "Layout", symbol: "rectangle.3.group"),
            nav(localization, title: NSLocalizedString("loc.title", comment: ""), symbol: "globe"),
            nav(FormControlsDemoVC(), title: "Form", symbol: "rectangle.and.pencil.and.ellipsis"),
            nav(CollectionGalleryDemoVC(), title: "Gallery", symbol: "square.grid.2x2"),
            nav(AnimationLabDemoVC(), title: "Motion", symbol: "wand.and.stars"),
            nav(IBInspectableDemoVC(), title: "Inspect", symbol: "slider.horizontal.3"),
            nav(SettingsDemoVC(), title: "Defaults", symbol: "gearshape"),
        ]
        addChild(tabs)
        view.addSubview(tabs.view)
        tabs.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabs.view.topAnchor.constraint(equalTo: view.topAnchor),
            tabs.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabs.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        tabs.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didApplyRoute else { return }
        didApplyRoute = true
        let environment = ProcessInfo.processInfo.environment
        if let route = environment["VOLY_SAMPLE_ROUTE"] {
            apply(route: route.split(separator: ",").map(String.init))
        }
        // A second route applied later, so a script can change something
        // (e.g. the language override) before these screens are created.
        if let route = environment["VOLY_SAMPLE_LATE_ROUTE"],
           let delay = environment["VOLY_SAMPLE_LATE_ROUTE_DELAY"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.apply(route: route.split(separator: ",").map(String.init))
            }
        }
    }

    /// Put the app into a known navigation state at launch, e.g.
    /// `VOLY_SAMPLE_ROUTE=localize,detail,sheet`. Used when driving the
    /// sample from scripts, where there is nobody to tap through to a screen.
    private func apply(route: [String]) {
        for step in route {
            switch step {
            case "localize":
                tabs.selectedIndex = 1
            case "detail":
                localization.loadViewIfNeeded()
                localization.showDetails(animated: false)
            case "sheet":
                localization.presentSheet(animated: false, pushingMore: false)
            case "sheet-detail":
                localization.presentSheet(animated: false, pushingMore: true)
            case "swiftui":
                let host = UIHostingController(rootView: SwiftUIStackDemo(depth: 3))
                host.modalPresentationStyle = .fullScreen
                present(host, animated: false)
            default:
                break
            }
        }
    }

    private func nav(_ root: UIViewController, title: String, symbol: String) -> UIViewController {
        let n = UINavigationController(rootViewController: root)
        root.title = title
        n.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        return n
    }
}
