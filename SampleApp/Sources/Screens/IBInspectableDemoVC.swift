import UIKit

final class IBInspectableDemoVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let badge = BadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.text = "New"
        badge.cornerRadius = 12
        badge.tintColor = .systemRed
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            badge.heightAnchor.constraint(equalToConstant: 40),
        ])
    }
}

/// A custom view with @IBInspectable properties so the runtime scanner has
/// something interesting to surface in Voly's PropertyPanel.
@IBDesignable
final class BadgeView: UIView {
    private let label = UILabel()

    @IBInspectable var text: String = "" {
        didSet { label.text = text; setNeedsLayout() }
    }
    @IBInspectable var cornerRadius: CGFloat = 0 {
        didSet { layer.cornerRadius = cornerRadius }
    }
    override var tintColor: UIColor! {
        didSet { backgroundColor = tintColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        layer.masksToBounds = true
        label.textColor = .white
        label.textAlignment = .center
        label.font = .boldSystemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
