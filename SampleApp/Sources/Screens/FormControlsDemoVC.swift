import UIKit

/// A dense form showcasing a wide variety of UIKit input controls so the
/// runtime inspector has rich content to surface.
final class FormControlsDemoVC: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let avatarWell = AvatarWell()
    private let nameField = UITextField()
    private let emailField = UITextField()
    private let passwordField = UITextField()
    private let bioTextView = UITextView()
    private let bioPlaceholder = UILabel()
    private let roleSegmented = UISegmentedControl(items: ["Viewer", "Editor", "Admin"])
    private let notificationsSwitch = UISwitch()
    private let analyticsSwitch = UISwitch()
    private let volumeSlider = UISlider()
    private let volumeValueLabel = UILabel()
    private let seatsStepper = UIStepper()
    private let seatsValueLabel = UILabel()
    private let birthdayPicker = UIDatePicker()
    private let themeColorWell = UIColorWell()
    private let previewCard = ProfilePreviewCard()
    private let saveButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        configureScrollView()
        configureSections()
        configureActions()
        refreshPreview()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "form_scroll"
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 32, trailing: 20)
        contentStack.accessibilityIdentifier = "form_stack"
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func configureSections() {
        contentStack.addArrangedSubview(previewCard)
        previewCard.accessibilityIdentifier = "form_preview_card"

        contentStack.addArrangedSubview(makeIdentitySection())
        contentStack.addArrangedSubview(makeBioSection())
        contentStack.addArrangedSubview(makePreferencesSection())
        contentStack.addArrangedSubview(makeSlidersSection())
        contentStack.addArrangedSubview(makeDateSection())
        contentStack.addArrangedSubview(makeButtonsRow())
    }

    private func makeIdentitySection() -> UIView {
        nameField.borderStyle = .roundedRect
        nameField.placeholder = "Full name"
        nameField.text = "Ada Lovelace"
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .next
        nameField.delegate = self
        nameField.accessibilityIdentifier = "form_name"

        emailField.borderStyle = .roundedRect
        emailField.placeholder = "you@example.com"
        emailField.text = "ada@voly.dev"
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.delegate = self
        emailField.accessibilityIdentifier = "form_email"

        passwordField.borderStyle = .roundedRect
        passwordField.placeholder = "Password"
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.delegate = self
        passwordField.accessibilityIdentifier = "form_password"

        avatarWell.translatesAutoresizingMaskIntoConstraints = false
        avatarWell.initials = "AL"
        avatarWell.accessibilityIdentifier = "form_avatar"
        avatarWell.onTap = { [weak self] in self?.cycleAvatarColor() }

        let fields = UIStackView(arrangedSubviews: [nameField, emailField, passwordField])
        fields.axis = .vertical
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [avatarWell, fields])
        row.axis = .horizontal
        row.spacing = 16
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            avatarWell.widthAnchor.constraint(equalToConstant: 64),
            avatarWell.heightAnchor.constraint(equalToConstant: 64),
        ])

        [nameField, emailField, passwordField].forEach {
            $0.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
        }

        return makeCard(title: "Identity", body: row)
    }

    private func makeBioSection() -> UIView {
        bioTextView.translatesAutoresizingMaskIntoConstraints = false
        bioTextView.font = .preferredFont(forTextStyle: .body)
        bioTextView.backgroundColor = .tertiarySystemBackground
        bioTextView.layer.cornerRadius = 10
        bioTextView.layer.borderWidth = 1
        bioTextView.layer.borderColor = UIColor.separator.cgColor
        bioTextView.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        bioTextView.isScrollEnabled = false
        bioTextView.delegate = self
        bioTextView.accessibilityIdentifier = "form_bio"

        bioPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        bioPlaceholder.text = "Tell us a little about yourself…"
        bioPlaceholder.textColor = .tertiaryLabel
        bioPlaceholder.font = .preferredFont(forTextStyle: .body)
        bioTextView.addSubview(bioPlaceholder)

        NSLayoutConstraint.activate([
            bioTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            bioPlaceholder.topAnchor.constraint(equalTo: bioTextView.topAnchor, constant: 12),
            bioPlaceholder.leadingAnchor.constraint(equalTo: bioTextView.leadingAnchor, constant: 16),
        ])

        return makeCard(title: "Biography", body: bioTextView)
    }

    private func makePreferencesSection() -> UIView {
        roleSegmented.selectedSegmentIndex = 1
        roleSegmented.accessibilityIdentifier = "form_role"
        roleSegmented.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        notificationsSwitch.isOn = true
        notificationsSwitch.accessibilityIdentifier = "form_notifications"
        analyticsSwitch.isOn = false
        analyticsSwitch.accessibilityIdentifier = "form_analytics"

        let notificationsRow = makeRow(title: "Push notifications", subtitle: "Delivery + marketing", trailing: notificationsSwitch)
        let analyticsRow = makeRow(title: "Share anonymous analytics", subtitle: "Helps us improve the product", trailing: analyticsSwitch)

        let stack = UIStackView(arrangedSubviews: [roleSegmented, divider(), notificationsRow, divider(), analyticsRow])
        stack.axis = .vertical
        stack.spacing = 12
        return makeCard(title: "Preferences", body: stack)
    }

    private func makeSlidersSection() -> UIView {
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 100
        volumeSlider.value = 35
        volumeSlider.minimumTrackTintColor = .systemIndigo
        volumeSlider.accessibilityIdentifier = "form_volume"
        volumeSlider.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        volumeValueLabel.textColor = .secondaryLabel
        volumeValueLabel.textAlignment = .right
        volumeValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let volumeRow = UIStackView(arrangedSubviews: [
            makeCaption("Volume"),
            volumeSlider,
            volumeValueLabel,
        ])
        volumeRow.axis = .horizontal
        volumeRow.spacing = 12
        volumeRow.alignment = .center

        seatsStepper.minimumValue = 1
        seatsStepper.maximumValue = 20
        seatsStepper.value = 5
        seatsStepper.accessibilityIdentifier = "form_seats"
        seatsStepper.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        seatsValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        seatsValueLabel.textColor = .secondaryLabel
        seatsValueLabel.textAlignment = .right
        seatsValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let seatsRow = UIStackView(arrangedSubviews: [
            makeCaption("Team seats"),
            UIView(),
            seatsValueLabel,
            seatsStepper,
        ])
        seatsRow.axis = .horizontal
        seatsRow.spacing = 12
        seatsRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [volumeRow, divider(), seatsRow])
        stack.axis = .vertical
        stack.spacing = 12
        return makeCard(title: "Levels", body: stack)
    }

    private func makeDateSection() -> UIView {
        birthdayPicker.datePickerMode = .date
        birthdayPicker.preferredDatePickerStyle = .compact
        birthdayPicker.date = Calendar.current.date(from: DateComponents(year: 1990, month: 5, day: 14)) ?? Date()
        birthdayPicker.accessibilityIdentifier = "form_birthday"
        birthdayPicker.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        themeColorWell.selectedColor = .systemIndigo
        themeColorWell.supportsAlpha = true
        themeColorWell.translatesAutoresizingMaskIntoConstraints = false
        themeColorWell.accessibilityIdentifier = "form_theme_color"
        themeColorWell.addTarget(self, action: #selector(controlChanged), for: .valueChanged)

        let birthdayRow = UIStackView(arrangedSubviews: [makeCaption("Birthday"), UIView(), birthdayPicker])
        birthdayRow.axis = .horizontal
        birthdayRow.spacing = 12
        birthdayRow.alignment = .center

        let colorRow = UIStackView(arrangedSubviews: [makeCaption("Theme accent"), UIView(), themeColorWell])
        colorRow.axis = .horizontal
        colorRow.spacing = 12
        colorRow.alignment = .center

        NSLayoutConstraint.activate([
            themeColorWell.widthAnchor.constraint(equalToConstant: 32),
            themeColorWell.heightAnchor.constraint(equalToConstant: 32),
        ])

        let stack = UIStackView(arrangedSubviews: [birthdayRow, divider(), colorRow])
        stack.axis = .vertical
        stack.spacing = 12
        return makeCard(title: "Profile details", body: stack)
    }

    private func makeButtonsRow() -> UIView {
        var saveConfig = UIButton.Configuration.filled()
        saveConfig.title = "Save changes"
        saveConfig.baseBackgroundColor = .systemIndigo
        saveConfig.cornerStyle = .large
        saveConfig.image = UIImage(systemName: "checkmark.circle.fill")
        saveConfig.imagePadding = 8
        saveButton.configuration = saveConfig
        saveButton.accessibilityIdentifier = "form_save"
        saveButton.addTarget(self, action: #selector(didTapSave), for: .touchUpInside)

        var resetConfig = UIButton.Configuration.gray()
        resetConfig.title = "Reset"
        resetConfig.cornerStyle = .large
        resetButton.configuration = resetConfig
        resetButton.accessibilityIdentifier = "form_reset"
        resetButton.addTarget(self, action: #selector(didTapReset), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [resetButton, saveButton])
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    private func configureActions() {
        notificationsSwitch.addTarget(self, action: #selector(controlChanged), for: .valueChanged)
        analyticsSwitch.addTarget(self, action: #selector(controlChanged), for: .valueChanged)
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case nameField: emailField.becomeFirstResponder()
        case emailField: passwordField.becomeFirstResponder()
        default: textField.resignFirstResponder()
        }
        return true
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        bioPlaceholder.isHidden = !textView.text.isEmpty
        refreshPreview()
    }

    // MARK: - Actions

    @objc private func textChanged(_ field: UITextField) {
        refreshPreview()
    }

    @objc private func controlChanged() {
        refreshPreview()
    }

    @objc private func didTapSave() {
        flash(previewCard, color: .systemGreen)
    }

    @objc private func didTapReset() {
        nameField.text = "Ada Lovelace"
        emailField.text = "ada@voly.dev"
        passwordField.text = ""
        bioTextView.text = ""
        bioPlaceholder.isHidden = false
        roleSegmented.selectedSegmentIndex = 1
        notificationsSwitch.setOn(true, animated: true)
        analyticsSwitch.setOn(false, animated: true)
        volumeSlider.setValue(35, animated: true)
        seatsStepper.value = 5
        themeColorWell.selectedColor = .systemIndigo
        refreshPreview()
        flash(previewCard, color: .systemOrange)
    }

    private func cycleAvatarColor() {
        let palette: [UIColor] = [.systemIndigo, .systemPink, .systemTeal, .systemOrange, .systemGreen]
        let current = avatarWell.accentColor
        let next = palette.first(where: { $0 != current }) ?? .systemIndigo
        avatarWell.accentColor = next
        refreshPreview()
    }

    private func refreshPreview() {
        previewCard.nameText = nameField.text ?? ""
        previewCard.emailText = emailField.text ?? ""
        previewCard.role = roleSegmented.titleForSegment(at: roleSegmented.selectedSegmentIndex) ?? "—"
        previewCard.seatCount = Int(seatsStepper.value)
        previewCard.bio = bioTextView.text
        previewCard.accent = themeColorWell.selectedColor ?? .systemIndigo
        previewCard.avatarColor = avatarWell.accentColor
        previewCard.initials = avatarWell.initials
        volumeValueLabel.text = "\(Int(volumeSlider.value))"
        seatsValueLabel.text = "\(Int(seatsStepper.value))"
    }

    private func flash(_ view: UIView, color: UIColor) {
        let original = view.layer.borderColor
        view.layer.borderColor = color.cgColor
        view.layer.borderWidth = 2
        UIView.animate(withDuration: 0.8, delay: 0.2, options: [.curveEaseOut]) {
            view.layer.borderWidth = 0
        } completion: { _ in
            view.layer.borderColor = original
        }
    }

    // MARK: - Builders

    private func makeCard(title: String, body: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let header = UILabel()
        header.text = title.uppercased()
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabel
        header.accessibilityIdentifier = "card_header_\(title.lowercased())"

        body.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [header, body])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }

    private func makeRow(title: String, subtitle: String, trailing: UIView) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [textStack, UIView(), trailing])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func makeCaption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .preferredFont(forTextStyle: .body)
        return l
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return v
    }
}

// MARK: - AvatarWell

final class AvatarWell: UIControl {
    var onTap: (() -> Void)?

    var accentColor: UIColor = .systemIndigo {
        didSet { updateColors() }
    }
    var initials: String = "" {
        didSet { label.text = initials }
    }

    private let label = UILabel()
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Avatar"
        updateColors()
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let inset: CGFloat = 3
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
    }

    private func updateColors() {
        backgroundColor = accentColor.withAlphaComponent(0.2)
        label.textColor = accentColor
        ring.strokeColor = accentColor.cgColor
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - ProfilePreviewCard

final class ProfilePreviewCard: UIView {
    var nameText: String = "" { didSet { nameLabel.text = nameText.isEmpty ? "—" : nameText } }
    var emailText: String = "" { didSet { emailLabel.text = emailText.isEmpty ? "—" : emailText } }
    var role: String = "" { didSet { roleBadge.title = role } }
    var seatCount: Int = 0 { didSet { seatsLabel.text = "\(seatCount) seats" } }
    var bio: String = "" {
        didSet {
            bioLabel.text = bio.isEmpty ? "No bio yet." : bio
            bioLabel.textColor = bio.isEmpty ? .tertiaryLabel : .label
        }
    }
    var accent: UIColor = .systemIndigo {
        didSet {
            backgroundColor = accent.withAlphaComponent(0.10)
            roleBadge.tint = accent
            layer.borderColor = accent.withAlphaComponent(0.35).cgColor
        }
    }
    var avatarColor: UIColor = .systemIndigo { didSet { miniAvatar.accentColor = avatarColor } }
    var initials: String = "" { didSet { miniAvatar.initials = initials } }

    private let miniAvatar = AvatarWell()
    private let nameLabel = UILabel()
    private let emailLabel = UILabel()
    private let roleBadge = PillBadge()
    private let seatsLabel = UILabel()
    private let bioLabel = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemIndigo.withAlphaComponent(0.35).cgColor
        backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.10)

        miniAvatar.translatesAutoresizingMaskIntoConstraints = false
        miniAvatar.isUserInteractionEnabled = false

        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.accessibilityIdentifier = "preview_name"
        emailLabel.font = .preferredFont(forTextStyle: .subheadline)
        emailLabel.textColor = .secondaryLabel
        emailLabel.accessibilityIdentifier = "preview_email"
        seatsLabel.font = .preferredFont(forTextStyle: .footnote)
        seatsLabel.textColor = .secondaryLabel
        bioLabel.font = .preferredFont(forTextStyle: .footnote)
        bioLabel.numberOfLines = 3
        bioLabel.accessibilityIdentifier = "preview_bio"

        let nameStack = UIStackView(arrangedSubviews: [nameLabel, emailLabel])
        nameStack.axis = .vertical
        nameStack.spacing = 2

        let topRow = UIStackView(arrangedSubviews: [miniAvatar, nameStack, UIView(), roleBadge])
        topRow.axis = .horizontal
        topRow.spacing = 12
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, bioLabel, seatsLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            miniAvatar.widthAnchor.constraint(equalToConstant: 48),
            miniAvatar.heightAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - PillBadge

final class PillBadge: UIView {
    var title: String = "" { didSet { label.text = title } }
    var tint: UIColor = .systemIndigo {
        didSet {
            backgroundColor = tint.withAlphaComponent(0.18)
            label.textColor = tint
        }
    }

    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        layer.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        tint = .systemIndigo
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
