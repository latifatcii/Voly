import UIKit

/// A multi-section gallery driven by UICollectionViewCompositionalLayout and
/// a diffable data source. Exercises several cell styles, supplementary
/// headers/footers, and orthogonal scrolling sections.
final class CollectionGalleryDemoVC: UIViewController {
    fileprivate enum Section: Int, CaseIterable {
        case featured
        case carousel
        case grid
        case list

        var title: String {
            switch self {
            case .featured: return "Featured"
            case .carousel: return "Trending now"
            case .grid: return "Palettes"
            case .list: return "Recent activity"
            }
        }

        var footer: String? {
            switch self {
            case .list: return "Pull to refresh • long-press to preview"
            default: return nil
            }
        }
    }

    fileprivate struct Item: Hashable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let accent: UIColor
        let section: Section
    }

    private let headerKind = "gallery.header"
    private let footerKind = "gallery.footer"

    private lazy var collectionView: UICollectionView = {
        UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    }()
    private lazy var dataSource = makeDataSource()
    private let refresher = UIRefreshControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "shuffle"),
            style: .plain,
            target: self,
            action: #selector(shuffle)
        )

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "gallery_collection"
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        refresher.addTarget(self, action: #selector(didPullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresher

        collectionView.dataSource = dataSource
        collectionView.delegate = self

        apply(animated: false)
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, env in
            guard let self, let section = Section(rawValue: sectionIndex) else { return nil }
            switch section {
            case .featured: return self.featuredSection()
            case .carousel: return self.carouselSection()
            case .grid: return self.gridSection(env: env)
            case .list: return self.listSection(env: env)
            }
        }
    }

    private func featuredSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                         heightDimension: .absolute(180)),
                                                       subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        section.boundarySupplementaryItems = [sectionHeader()]
        return section
    }

    private func carouselSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(160),
                                                                         heightDimension: .absolute(200)),
                                                       subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.contentInsets = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        section.boundarySupplementaryItems = [sectionHeader()]
        return section
    }

    private func gridSection(env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let columns = env.container.effectiveContentSize.width > 500 ? 3 : 2
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .fractionalHeight(1)))
        item.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                         heightDimension: .absolute(140)),
                                                       repeatingSubitem: item, count: columns)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        section.boundarySupplementaryItems = [sectionHeader()]
        return section
    }

    private func listSection(env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self else { return nil }
            let archive = UIContextualAction(style: .normal, title: "Archive") { [weak self] _, _, done in
                self?.archive(at: indexPath)
                done(true)
            }
            archive.backgroundColor = .systemOrange
            archive.image = UIImage(systemName: "archivebox")
            return UISwipeActionsConfiguration(actions: [archive])
        }
        return NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
    }

    private func sectionHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: headerKind, alignment: .top)
    }

    // MARK: - Data source

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
        let featuredRegistration = UICollectionView.CellRegistration<FeaturedBannerCell, Item> { cell, _, item in
            cell.configure(with: item)
        }
        let carouselRegistration = UICollectionView.CellRegistration<CarouselCardCell, Item> { cell, _, item in
            cell.configure(with: item)
        }
        let gridRegistration = UICollectionView.CellRegistration<PaletteTileCell, Item> { cell, _, item in
            cell.configure(with: item)
        }
        let listRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.secondaryText = item.subtitle
            content.image = UIImage(systemName: item.symbol)
            content.imageProperties.tintColor = item.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator(), .label(text: "›")]
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderView>(elementKind: headerKind) { view, _, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            view.title = section.title
            view.accessibilityIdentifier = "gallery_header_\(section.title.lowercased())"
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<SectionFooterView>(elementKind: UICollectionView.elementKindSectionFooter) { view, _, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            view.text = section.footer
        }

        let ds = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item.section {
            case .featured:
                return collectionView.dequeueConfiguredReusableCell(using: featuredRegistration, for: indexPath, item: item)
            case .carousel:
                return collectionView.dequeueConfiguredReusableCell(using: carouselRegistration, for: indexPath, item: item)
            case .grid:
                return collectionView.dequeueConfiguredReusableCell(using: gridRegistration, for: indexPath, item: item)
            case .list:
                return collectionView.dequeueConfiguredReusableCell(using: listRegistration, for: indexPath, item: item)
            }
        }
        ds.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == self.headerKind {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            if kind == UICollectionView.elementKindSectionFooter {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
            return nil
        }
        return ds
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(Sample.featured, toSection: .featured)
        snapshot.appendItems(Sample.carousel, toSection: .carousel)
        snapshot.appendItems(Sample.palettes, toSection: .grid)
        snapshot.appendItems(Sample.activity, toSection: .list)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - Actions

    @objc private func shuffle() {
        var snapshot = dataSource.snapshot()
        for section in Section.allCases {
            let items = snapshot.itemIdentifiers(inSection: section)
            snapshot.deleteItems(items)
            snapshot.appendItems(items.shuffled(), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func didPullToRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.shuffle()
            self?.refresher.endRefreshing()
        }
    }

    private func archive(at indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        var snap = dataSource.snapshot()
        snap.deleteItems([item])
        dataSource.apply(snap, animatingDifferences: true)
    }
}

extension CollectionGalleryDemoVC: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let alert = UIAlertController(title: item.title, message: item.subtitle, preferredStyle: .actionSheet)
        alert.addAction(.init(title: "Open", style: .default))
        alert.addAction(.init(title: "Close", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Cells

final class FeaturedBannerCell: UICollectionViewCell {
    private let gradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let symbolView = UIImageView()
    private let pill = PillBadge()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true
        contentView.layer.addSublayer(gradient)
        gradient.startPoint = .init(x: 0, y: 0)
        gradient.endPoint = .init(x: 1, y: 1)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .white.withAlphaComponent(0.85)
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        symbolView.tintColor = .white.withAlphaComponent(0.85)
        symbolView.contentMode = .scaleAspectFit
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.title = "Featured"
        pill.tint = .white

        contentView.addSubview(pill)
        contentView.addSubview(symbolView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            symbolView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            symbolView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            symbolView.widthAnchor.constraint(equalToConstant: 60),
            symbolView.heightAnchor.constraint(equalToConstant: 60),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = contentView.bounds
    }

    fileprivate func configure(with item: CollectionGalleryDemoVC.Item) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        symbolView.image = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .bold))
        gradient.colors = [item.accent.cgColor, item.accent.withAlphaComponent(0.6).cgColor]
        accessibilityIdentifier = "featured_\(item.title.lowercased())"
    }
}

final class CarouselCardCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        contentView.addSubview(imageView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            imageView.widthAnchor.constraint(equalToConstant: 56),
            imageView.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    fileprivate func configure(with item: CollectionGalleryDemoVC.Item) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        imageView.image = UIImage(systemName: item.symbol)
        imageView.tintColor = item.accent
        accessibilityIdentifier = "carousel_\(item.title.lowercased())"
    }
}

final class PaletteTileCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let swatches = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        swatches.axis = .horizontal
        swatches.spacing = 6
        swatches.distribution = .fillEqually
        swatches.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(swatches)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            swatches.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            swatches.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            swatches.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            swatches.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    fileprivate func configure(with item: CollectionGalleryDemoVC.Item) {
        titleLabel.text = item.title
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let base = item.accent
        let ramp = [base.withAlphaComponent(0.3), base.withAlphaComponent(0.55), base, base.withAlphaComponent(0.85)]
        for color in ramp {
            let v = UIView()
            v.backgroundColor = color
            v.layer.cornerRadius = 6
            swatches.addArrangedSubview(v)
        }
        accessibilityIdentifier = "palette_\(item.title.lowercased())"
    }
}

final class SectionHeaderView: UICollectionReusableView {
    var title: String = "" { didSet { label.text = title } }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class SectionFooterView: UICollectionReusableView {
    var text: String? { didSet { label.text = text } }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Sample data

private enum Sample {
    static let featured: [CollectionGalleryDemoVC.Item] = [
        .init(title: "Midnight",  subtitle: "Dark theme tuned for OLED",      symbol: "moon.stars.fill",  accent: .systemIndigo, section: .featured),
        .init(title: "Aurora",    subtitle: "Vibrant gradients from the arctic", symbol: "sparkles",      accent: .systemTeal,   section: .featured),
    ]

    static let carousel: [CollectionGalleryDemoVC.Item] = [
        .init(title: "Ocean",  subtitle: "Cool blue tones",     symbol: "water.waves",    accent: .systemBlue,   section: .carousel),
        .init(title: "Forest", subtitle: "Earth and pine",       symbol: "leaf.fill",      accent: .systemGreen,  section: .carousel),
        .init(title: "Sunset", subtitle: "Warm dusk palette",    symbol: "sun.horizon.fill", accent: .systemOrange, section: .carousel),
        .init(title: "Candy",  subtitle: "Playful pinks",        symbol: "heart.fill",     accent: .systemPink,   section: .carousel),
        .init(title: "Mono",   subtitle: "Quiet monochrome",     symbol: "circle.lefthalf.filled", accent: .systemGray, section: .carousel),
    ]

    static let palettes: [CollectionGalleryDemoVC.Item] = [
        .init(title: "Citrus",   subtitle: "",  symbol: "",  accent: .systemYellow, section: .grid),
        .init(title: "Berry",    subtitle: "",  symbol: "",  accent: .systemPurple, section: .grid),
        .init(title: "Ocean",    subtitle: "",  symbol: "",  accent: .systemTeal,   section: .grid),
        .init(title: "Lava",     subtitle: "",  symbol: "",  accent: .systemRed,    section: .grid),
        .init(title: "Mint",     subtitle: "",  symbol: "",  accent: .systemMint,   section: .grid),
        .init(title: "Slate",    subtitle: "",  symbol: "",  accent: .systemGray,   section: .grid),
    ]

    static let activity: [CollectionGalleryDemoVC.Item] = [
        .init(title: "Published release",    subtitle: "Voly 0.4 • 2 hours ago",    symbol: "checkmark.seal.fill", accent: .systemGreen,  section: .list),
        .init(title: "Schema migration",     subtitle: "inspector_items table",      symbol: "cylinder.split.1x2.fill", accent: .systemBlue,   section: .list),
        .init(title: "Invited teammate",     subtitle: "alex@voly.dev",              symbol: "person.crop.circle.badge.plus", accent: .systemIndigo, section: .list),
        .init(title: "New bug report",       subtitle: "Layout inspector hangs",     symbol: "ant.fill",           accent: .systemOrange, section: .list),
        .init(title: "Daily digest",         subtitle: "12 sessions, 3 insights",    symbol: "envelope.badge.fill", accent: .systemPurple, section: .list),
    ]
}

