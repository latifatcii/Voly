#if canImport(UIKit)
import UIKit
#if canImport(VolyModels)
import VolyModels
#endif
#if canImport(VolyCodables)
import VolyCodables
#endif

@MainActor
public final class PreviewHostVC: UIViewController {
    private let child: UIViewController
    private var currentConfig: PreviewConfig?
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    public init(wrapping child: UIViewController) {
        self.child = child
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(child)
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = child.view.widthAnchor.constraint(equalTo: view.widthAnchor)
        heightConstraint = child.view.heightAnchor.constraint(equalTo: view.heightAnchor)
        NSLayoutConstraint.activate([
            child.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            child.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            widthConstraint,
            heightConstraint,
        ])
        child.didMove(toParent: self)
    }

    @discardableResult
    public func apply(_ config: PreviewConfig) -> PreviewConfig.Applied {
        var warnings: [String] = []

        // Size
        widthConstraint.isActive = false
        heightConstraint.isActive = false
        widthConstraint = child.view.widthAnchor.constraint(equalToConstant: CGFloat(config.size.width))
        heightConstraint = child.view.heightAnchor.constraint(equalToConstant: CGFloat(config.size.height))
        widthConstraint.isActive = true
        heightConstraint.isActive = true

        // Safe area
        child.additionalSafeAreaInsets = UIEdgeInsets(
            top: CGFloat(config.safeAreaInsets.top),
            left: CGFloat(config.safeAreaInsets.left),
            bottom: CGFloat(config.safeAreaInsets.bottom),
            right: CGFloat(config.safeAreaInsets.right)
        )

        // Trait overrides (iOS 17+ traitOverrides API)
        var overrides = child.traitOverrides
        if config.horizontalSizeClass != .unspecified {
            overrides.horizontalSizeClass = config.horizontalSizeClass.ui
        } else {
            overrides.remove(UITraitHorizontalSizeClass.self)
        }
        if config.verticalSizeClass != .unspecified {
            overrides.verticalSizeClass = config.verticalSizeClass.ui
        } else {
            overrides.remove(UITraitVerticalSizeClass.self)
        }
        if config.userInterfaceStyle != .unspecified {
            overrides.userInterfaceStyle = config.userInterfaceStyle.ui
        } else {
            overrides.remove(UITraitUserInterfaceStyle.self)
        }
        if config.contentSizeCategory != .unspecified {
            overrides.preferredContentSizeCategory = config.contentSizeCategory.ui
        } else {
            overrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        overrides.layoutDirection = config.layoutDirection.ui
        child.traitOverrides = overrides

        if config.orientation != (currentConfig?.orientation ?? .portrait) {
            warnings.append("Orientation override is visual-only; UIDevice.current.orientation is unchanged.")
        }
        let hostScale = Double(view.window?.screen.scale ?? 2)
        if abs(config.displayScale - hostScale) > 0.01 {
            warnings.append("Display scale override is informational; UIScreen.scale in the running process is unchanged.")
        }

        currentConfig = config
        view.setNeedsLayout()
        view.layoutIfNeeded()

        return .init(
            actualSize: CGSizeCodable(child.view.bounds.size),
            warnings: warnings
        )
    }

    public func teardown() {
        widthConstraint.isActive = false
        heightConstraint.isActive = false
        widthConstraint = child.view.widthAnchor.constraint(equalTo: view.widthAnchor)
        heightConstraint = child.view.heightAnchor.constraint(equalTo: view.heightAnchor)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        var overrides = child.traitOverrides
        overrides.remove(UITraitHorizontalSizeClass.self)
        overrides.remove(UITraitVerticalSizeClass.self)
        overrides.remove(UITraitUserInterfaceStyle.self)
        overrides.remove(UITraitPreferredContentSizeCategory.self)
        overrides.remove(UITraitLayoutDirection.self)
        child.traitOverrides = overrides
        child.additionalSafeAreaInsets = .zero
        currentConfig = nil
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}

extension PreviewConfig.SizeClass {
    var ui: UIUserInterfaceSizeClass {
        switch self {
        case .compact: return .compact
        case .regular: return .regular
        case .unspecified: return .unspecified
        }
    }
}

extension PreviewConfig.UIStyle {
    var ui: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .unspecified: return .unspecified
        }
    }
}

extension PreviewConfig.ContentSize {
    var ui: UIContentSizeCategory {
        switch self {
        case .xs: return .extraSmall
        case .s: return .small
        case .m: return .medium
        case .l: return .large
        case .xl: return .extraLarge
        case .xxl: return .extraExtraLarge
        case .xxxl: return .extraExtraExtraLarge
        case .ax1: return .accessibilityMedium
        case .ax2: return .accessibilityLarge
        case .ax3: return .accessibilityExtraLarge
        case .ax4: return .accessibilityExtraExtraLarge
        case .ax5: return .accessibilityExtraExtraExtraLarge
        case .unspecified: return .unspecified
        }
    }
}

extension PreviewConfig.LayoutDirection {
    var ui: UITraitEnvironmentLayoutDirection {
        switch self {
        case .ltr: return .leftToRight
        case .rtl: return .rightToLeft
        }
    }
}
#endif
