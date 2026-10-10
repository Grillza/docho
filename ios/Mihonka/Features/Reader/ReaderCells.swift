import Nuke
import UIKit

/// One page, or two side by side (a spread), in a zooming scroll view, centred while smaller
/// than the view. Until an image arrives it's laid out as a portrait page.
final class PageCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseIdentifier = "page"
    private static let placeholderAspect: CGFloat = 2 / 3

    /// Called with each page's image size once it has loaded.
    var onImageSize: (Int, CGSize) -> Void = { _, _ in }

    private let scrollView = UIScrollView()
    private let container = UIView()
    private var imageViews: [UIImageView] = []
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var loadTasks: [Task<Void, Never>] = []
    private var pages: [Int] = []
    private var rightToLeft = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(container)
        contentView.addSubview(scrollView)

        spinner.color = .lightGray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .lightGray
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        contentView.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTasks.forEach { $0.cancel() }
        loadTasks = []
        resetZoom()
    }

    /// Shows `pages` (one or two) from `requests`, in reading order.
    func configure(requests: [ImageRequest?], pages: [Int], pageCount: Int, rightToLeft: Bool) {
        loadTasks.forEach { $0.cancel() }
        loadTasks = []
        self.pages = pages
        self.rightToLeft = rightToLeft
        accessibilityLabel = pages.count == 1
            ? String(localized: "Page \(pages[0] + 1) of \(pageCount)")
            : String(localized: "Pages \(pages[0] + 1)–\(pages[pages.count - 1] + 1) of \(pageCount)")
        accessibilityValue = nil
        while imageViews.count < pages.count {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            container.addSubview(imageView)
            imageViews.append(imageView)
        }
        for (index, imageView) in imageViews.enumerated() {
            imageView.image = nil
            imageView.isHidden = index >= pages.count
        }
        errorLabel.isHidden = true
        layoutImages()
        for (index, request) in requests.enumerated() where index < pages.count {
            load(request, into: index)
        }
    }

    private func load(_ request: ImageRequest?, into index: Int) {
        guard let request else { return }
        if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
            show(cached.image, at: index)
            return
        }
        spinner.startAnimating()
        loadTasks.append(Task { [weak self] in
            do {
                let image = try await ImagePipeline.shared.image(for: request)
                self?.show(image, at: index)
            } catch {
                guard !Task.isCancelled else { return }
                self?.spinner.stopAnimating()
                self?.errorLabel.text = String(localized: "Couldn't load this page.\n\(error.localizedDescription)")
                self?.errorLabel.isHidden = false
            }
        })
    }

    private func show(_ image: UIImage, at index: Int) {
        imageViews[index].image = image
        let visible = imageViews.prefix(pages.count)
        if visible.allSatisfy({ $0.image != nil }) {
            spinner.stopAnimating()
            accessibilityValue = String(localized: "Loaded")
        }
        if scrollView.zoomScale == 1 { layoutImages() }
        onImageSize(pages[index], image.size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.zoomScale == 1 { layoutImages() }
    }

    /// Fits the pages, side by side at one height, in the cell and centres them. In right to
    /// left, the first page is on the right.
    private func layoutImages() {
        let bounds = scrollView.bounds.size
        guard !pages.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let aspects = imageViews.prefix(pages.count).map { view -> CGFloat in
            guard let size = view.image?.size, size.width > 0, size.height > 0 else { return Self.placeholderAspect }
            return size.width / size.height
        }
        let height = min(bounds.height, bounds.width / aspects.reduce(0, +))
        var left: CGFloat = 0
        let order = rightToLeft ? Array(aspects.indices.reversed()) : Array(aspects.indices)
        for index in order {
            let width = aspects[index] * height
            imageViews[index].frame = CGRect(x: left, y: 0, width: width, height: height)
            left += width
        }
        scrollView.zoomScale = 1
        container.frame = CGRect(x: 0, y: 0, width: left, height: height)
        scrollView.contentSize = container.frame.size
        centerContent()
    }

    private func centerContent() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        scrollView.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - content.height) / 2),
            left: max(0, (bounds.width - content.width) / 2),
            bottom: 0,
            right: 0
        )
    }

    func resetZoom() {
        guard scrollView.zoomScale != 1 else { return }
        scrollView.setZoomScale(1, animated: false)
    }

    func toggleZoom(at point: CGPoint) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let location = container.convert(point, from: self)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            let origin = CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }
}

/// Which pages share a screen in two-page mode.
enum PageSpreads {
    /// Pairs pages in reading order. Wide pages (already a spread in the scan) stand alone, and so
    /// does the first page when `coverAlone` is on; a page left over after a wide one or at the
    /// end stands alone too.
    static func pair(pageCount: Int, wide: Set<Int>, coverAlone: Bool) -> [[Int]] {
        var spreads: [[Int]] = []
        var page = 0
        if coverAlone, pageCount > 0 {
            spreads.append([0])
            page = 1
        }
        while page < pageCount {
            if wide.contains(page) || page + 1 >= pageCount || wide.contains(page + 1) {
                spreads.append([page])
                page += 1
            } else {
                spreads.append([page, page + 1])
                page += 2
            }
        }
        return spreads
    }
}

/// The page between chapters: what was finished and what comes next.
final class TransitionCell: UICollectionViewCell {
    static let reuseIdentifier = "transition"

    private let currentLabel = UILabel()
    private let otherLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [currentLabel, otherLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        currentLabel.font = .preferredFont(forTextStyle: .body)
        currentLabel.textColor = .lightGray
        otherLabel.font = .preferredFont(forTextStyle: .title3)
        otherLabel.textColor = .white
        for label in [currentLabel, otherLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(current: String, other: String?, none: String) {
        currentLabel.text = current
        otherLabel.text = other ?? none
        accessibilityLabel = [current, other ?? none].joined(separator: ". ")
        accessibilityIdentifier = "reader.transition"
    }
}
