import UIKit

/// Writes a few keys into UserDefaults on load so Voly has something to show.
final class SettingsDemoVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "voly.sample.launchCount") == nil {
            defaults.set(0, forKey: "voly.sample.launchCount")
        }
        let count = defaults.integer(forKey: "voly.sample.launchCount") + 1
        defaults.set(count, forKey: "voly.sample.launchCount")
        defaults.set("ready", forKey: "voly.sample.status")
        defaults.set(true, forKey: "voly.sample.analytics.enabled")

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.text = "This screen seeds UserDefaults with keys prefixed 'voly.sample.*'. Open the UserDefaults panel in Voly.app to edit them."
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
        ])
    }
}
