import UIKit

final class AutoLayoutDemoVC: UIViewController {
    private let card = UIView()
    private let title1 = UILabel()
    private let subtitle1 = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.separator.cgColor
        card.accessibilityIdentifier = "hero_card"
        view.addSubview(card)

        title1.translatesAutoresizingMaskIntoConstraints = false
        title1.text = "Voly Sample"
        title1.font = .preferredFont(forTextStyle: .title2)
        title1.accessibilityIdentifier = "hero_title"

        subtitle1.translatesAutoresizingMaskIntoConstraints = false
        subtitle1.text = "Inspect and edit me from macOS."
        subtitle1.font = .preferredFont(forTextStyle: .body)
        subtitle1.textColor = .secondaryLabel
        subtitle1.numberOfLines = 0
        subtitle1.accessibilityIdentifier = "hero_subtitle"

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Tap me", for: .normal)
        button.configuration = .filled()

        card.addSubview(title1)
        card.addSubview(subtitle1)
        card.addSubview(button)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 320).with(identifier: "card_width"),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

            title1.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            title1.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            title1.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            subtitle1.topAnchor.constraint(equalTo: title1.bottomAnchor, constant: 8),
            subtitle1.leadingAnchor.constraint(equalTo: title1.leadingAnchor),
            subtitle1.trailingAnchor.constraint(equalTo: title1.trailingAnchor),

            button.topAnchor.constraint(equalTo: subtitle1.bottomAnchor, constant: 16),
            button.leadingAnchor.constraint(equalTo: title1.leadingAnchor),
            button.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -20),
        ])
    }
}

extension NSLayoutConstraint {
    fileprivate func with(identifier: String) -> NSLayoutConstraint {
        self.identifier = identifier
        return self
    }
}
