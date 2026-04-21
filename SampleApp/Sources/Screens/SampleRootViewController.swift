import UIKit

final class SampleRootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let tabs = UITabBarController()
        tabs.viewControllers = [
            nav(AutoLayoutDemoVC(), title: "Layout", symbol: "rectangle.3.group"),
            nav(IBInspectableDemoVC(), title: "Inspectable", symbol: "slider.horizontal.3"),
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

    private func nav(_ root: UIViewController, title: String, symbol: String) -> UIViewController {
        let n = UINavigationController(rootViewController: root)
        root.title = title
        n.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        return n
    }
}
