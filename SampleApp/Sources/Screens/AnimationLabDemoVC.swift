import UIKit

/// A playground of Core Animation + gesture-driven UIKit. The hero view supports
/// pan/pinch/rotate, a CAEmitterLayer can be toggled, and a ring of animated
/// shape layers reacts to control changes. Useful for exercising layer/view
/// trees in Voly's inspector.
final class AnimationLabDemoVC: UIViewController {
    private let canvas = UIView()
    private let hero = HeroShapeView()
    private let orbit = OrbitRingView()

    private let bottomBar = UIView()
    private let shapeSegmented = UISegmentedControl(items: ["Star", "Heart", "Hex"])
    private let hueSlider = UISlider()
    private let sparkleSwitch = UISwitch()
    private let sparkleLabel = UILabel()
    private let animateButton = UIButton(type: .system)

    private var emitter: CAEmitterLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        configureCanvas()
        configureControls()
        configureGestures()
        updateTintFromSlider()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        centerHero()
        emitter?.emitterPosition = .init(x: canvas.bounds.midX, y: -10)
        emitter?.emitterSize = .init(width: canvas.bounds.width, height: 2)
    }

    private func configureCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .secondarySystemBackground
        canvas.layer.cornerRadius = 24
        canvas.layer.cornerCurve = .continuous
        canvas.layer.masksToBounds = true
        canvas.accessibilityIdentifier = "anim_canvas"
        view.addSubview(canvas)

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.backgroundColor = .secondarySystemGroupedBackground
        bottomBar.layer.cornerRadius = 20
        bottomBar.layer.cornerCurve = .continuous
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            canvas.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -16),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        orbit.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(orbit)
        NSLayoutConstraint.activate([
            orbit.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            orbit.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            orbit.widthAnchor.constraint(equalToConstant: 260),
            orbit.heightAnchor.constraint(equalToConstant: 260),
        ])

        hero.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(hero)
        hero.widthAnchor.constraint(equalToConstant: 140).isActive = true
        hero.heightAnchor.constraint(equalToConstant: 140).isActive = true
        hero.accessibilityIdentifier = "anim_hero"
    }

    private func configureControls() {
        shapeSegmented.selectedSegmentIndex = 0
        shapeSegmented.accessibilityIdentifier = "anim_shape"
        shapeSegmented.addTarget(self, action: #selector(shapeChanged), for: .valueChanged)

        hueSlider.minimumValue = 0
        hueSlider.maximumValue = 1
        hueSlider.value = 0.68
        hueSlider.accessibilityIdentifier = "anim_hue"
        hueSlider.addTarget(self, action: #selector(hueChanged), for: .valueChanged)

        sparkleSwitch.isOn = false
        sparkleSwitch.accessibilityIdentifier = "anim_sparkle"
        sparkleSwitch.addTarget(self, action: #selector(sparkleToggled), for: .valueChanged)

        sparkleLabel.text = "Sparkles"
        sparkleLabel.font = .preferredFont(forTextStyle: .body)

        var config = UIButton.Configuration.tinted()
        config.title = "Pulse"
        config.image = UIImage(systemName: "wand.and.stars")
        config.imagePadding = 6
        config.cornerStyle = .large
        animateButton.configuration = config
        animateButton.accessibilityIdentifier = "anim_pulse"
        animateButton.addTarget(self, action: #selector(pulse), for: .touchUpInside)

        let hueRow = UIStackView(arrangedSubviews: [iconLabel(symbol: "paintpalette"), hueSlider])
        hueRow.axis = .horizontal
        hueRow.spacing = 12
        hueRow.alignment = .center

        let sparkleRow = UIStackView(arrangedSubviews: [iconLabel(symbol: "sparkles"), sparkleLabel, UIView(), sparkleSwitch])
        sparkleRow.axis = .horizontal
        sparkleRow.spacing = 12
        sparkleRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [shapeSegmented, hueRow, sparkleRow, animateButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
        ])
    }

    private func configureGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))

        pinch.delegate = self
        rotate.delegate = self

        hero.addGestureRecognizer(pan)
        hero.addGestureRecognizer(pinch)
        hero.addGestureRecognizer(rotate)
        hero.addGestureRecognizer(tap)
        hero.addGestureRecognizer(longPress)
        hero.isUserInteractionEnabled = true
    }

    private func centerHero() {
        guard hero.superview != nil, hero.center == .zero else { return }
        hero.center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    }

    private func updateTintFromSlider() {
        let color = UIColor(hue: CGFloat(hueSlider.value), saturation: 0.7, brightness: 0.95, alpha: 1)
        hero.tintColor = color
        orbit.tintColor = color
        animateButton.tintColor = color
    }

    // MARK: - Actions

    @objc private func shapeChanged() {
        hero.shape = HeroShapeView.Shape(rawValue: shapeSegmented.selectedSegmentIndex) ?? .star
        pulse()
    }

    @objc private func hueChanged() {
        updateTintFromSlider()
    }

    @objc private func sparkleToggled() {
        if sparkleSwitch.isOn {
            startEmitter()
        } else {
            stopEmitter()
        }
    }

    @objc private func pulse() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.9
        spring.toValue = 1.0
        spring.duration = 0.7
        spring.damping = 6
        spring.initialVelocity = 8
        hero.layer.add(spring, forKey: "pulse")
        orbit.pulse()
    }

    // MARK: - Gestures

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard let target = g.view, let parent = target.superview else { return }
        let translation = g.translation(in: parent)
        target.center = CGPoint(x: target.center.x + translation.x, y: target.center.y + translation.y)
        g.setTranslation(.zero, in: parent)
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard let target = g.view else { return }
        target.transform = target.transform.scaledBy(x: g.scale, y: g.scale)
        g.scale = 1
    }

    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        guard let target = g.view else { return }
        target.transform = target.transform.rotated(by: g.rotation)
        g.rotation = 0
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        pulse()
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.2) {
            self.hero.transform = .identity
            self.hero.center = CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY)
        }
    }

    // MARK: - Emitter

    private func startEmitter() {
        let layer = CAEmitterLayer()
        layer.emitterShape = .line
        layer.emitterMode = .surface
        layer.emitterPosition = .init(x: canvas.bounds.midX, y: -10)
        layer.emitterSize = .init(width: canvas.bounds.width, height: 2)
        layer.birthRate = 1

        let cell = CAEmitterCell()
        cell.birthRate = 8
        cell.lifetime = 5
        cell.velocity = 80
        cell.velocityRange = 40
        cell.yAcceleration = 60
        cell.emissionRange = .pi / 6
        cell.scale = 0.3
        cell.scaleRange = 0.2
        cell.alphaSpeed = -0.2
        cell.spin = 2
        cell.spinRange = 4
        cell.contents = sparkleImage().cgImage
        cell.color = hero.tintColor.cgColor
        layer.emitterCells = [cell]

        canvas.layer.addSublayer(layer)
        self.emitter = layer
    }

    private func stopEmitter() {
        emitter?.birthRate = 0
        let doomed = emitter
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak doomed] in
            doomed?.removeFromSuperlayer()
        }
        emitter = nil
    }

    private func sparkleImage() -> UIImage {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
        }
    }

    private func iconLabel(symbol: String) -> UIImageView {
        let v = UIImageView(image: UIImage(systemName: symbol))
        v.tintColor = .secondaryLabel
        v.contentMode = .scaleAspectFit
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }
}

extension AnimationLabDemoVC: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - HeroShapeView

final class HeroShapeView: UIView {
    enum Shape: Int { case star, heart, hex }

    var shape: Shape = .star { didSet { rebuildPath() } }

    override var tintColor: UIColor! {
        didSet { applyTint() }
    }

    private let shapeLayer = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let highlight = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(gradient)
        gradient.mask = shapeLayer
        shapeLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(highlight)
        highlight.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        shapeLayer.frame = bounds
        highlight.frame = bounds
        rebuildPath()
    }

    private func rebuildPath() {
        let path: UIBezierPath
        switch shape {
        case .star: path = Self.starPath(in: bounds.insetBy(dx: 6, dy: 6))
        case .heart: path = Self.heartPath(in: bounds.insetBy(dx: 6, dy: 6))
        case .hex: path = Self.hexPath(in: bounds.insetBy(dx: 6, dy: 6))
        }
        shapeLayer.path = path.cgPath

        let h = UIBezierPath(ovalIn: CGRect(x: bounds.midX - 22, y: bounds.midY - 32, width: 20, height: 12))
        highlight.path = h.cgPath
    }

    private func applyTint() {
        let base = tintColor ?? .systemIndigo
        gradient.colors = [
            base.lighter(by: 0.2).cgColor,
            base.cgColor,
            base.darker(by: 0.2).cgColor,
        ]
        gradient.startPoint = .init(x: 0, y: 0)
        gradient.endPoint = .init(x: 1, y: 1)
        layer.shadowColor = base.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = .init(width: 0, height: 6)
    }

    // MARK: Path helpers

    private static func starPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let points = 5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.45
        var angle = -CGFloat.pi / 2
        let step = .pi / CGFloat(points)
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outerRadius : innerRadius
            let p = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            angle += step
        }
        path.close()
        return path
    }

    private static func heartPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.25))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.35),
                      controlPoint1: CGPoint(x: rect.midX - w * 0.2, y: rect.minY),
                      controlPoint2: CGPoint(x: rect.minX, y: rect.minY + h * 0.1))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      controlPoint1: CGPoint(x: rect.minX, y: rect.minY + h * 0.6),
                      controlPoint2: CGPoint(x: rect.midX - w * 0.2, y: rect.maxY - h * 0.05))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.35),
                      controlPoint1: CGPoint(x: rect.midX + w * 0.2, y: rect.maxY - h * 0.05),
                      controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.6))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.25),
                      controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.1),
                      controlPoint2: CGPoint(x: rect.midX + w * 0.2, y: rect.minY))
        path.close()
        return path
    }

    private static func hexPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<6 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
        return path
    }
}

// MARK: - OrbitRingView

final class OrbitRingView: UIView {
    override var tintColor: UIColor! { didSet { applyColor() } }

    private let ring = CAShapeLayer()
    private let nodes: [CAShapeLayer] = (0..<8).map { _ in CAShapeLayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1
        ring.lineDashPattern = [3, 6]
        layer.addSublayer(ring)

        for node in nodes {
            node.fillColor = UIColor.systemIndigo.cgColor
            layer.addSublayer(node)
        }
        spin()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - 6
        let ringPath = UIBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        ring.path = ringPath.cgPath
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for (i, node) in nodes.enumerated() {
            let angle = CGFloat(i) / CGFloat(nodes.count) * 2 * .pi
            let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let size: CGFloat = 10 + CGFloat(i % 3) * 2
            node.frame = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            node.path = UIBezierPath(ovalIn: node.bounds).cgPath
        }
    }

    private func applyColor() {
        ring.strokeColor = tintColor.withAlphaComponent(0.5).cgColor
        for (i, node) in nodes.enumerated() {
            let alpha = 0.3 + CGFloat(i) / CGFloat(nodes.count) * 0.7
            node.fillColor = tintColor.withAlphaComponent(alpha).cgColor
        }
    }

    private func spin() {
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = 2 * CGFloat.pi
        anim.duration = 18
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "spin")
    }

    func pulse() {
        for (i, node) in nodes.enumerated() {
            let anim = CASpringAnimation(keyPath: "transform.scale")
            anim.fromValue = 0.6
            anim.toValue = 1.0
            anim.damping = 5
            anim.initialVelocity = 10
            anim.duration = 0.9
            anim.beginTime = CACurrentMediaTime() + Double(i) * 0.04
            node.add(anim, forKey: "pulse")
        }
    }
}

// MARK: - UIColor helpers

private extension UIColor {
    func lighter(by amount: CGFloat) -> UIColor { adjustBrightness(by: 1 + amount) }
    func darker(by amount: CGFloat) -> UIColor { adjustBrightness(by: 1 - amount) }

    func adjustBrightness(by factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: min(max(b * factor, 0), 1), alpha: a)
    }
}
