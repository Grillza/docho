import Nuke
import UIKit

/// One page: an image in a zooming scroll view, centred while it's smaller than the view.
final class PageCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseIdentifier = "page"

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var request: ImageRequest?

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
        scrollView.addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
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
        loadTask?.cancel()
        imageView.image = nil
        resetZoom()
    }

    func configure(request: ImageRequest?, page: Int, pageCount: Int) {
        accessibilityLabel = String(localized: "Page \(page + 1) of \(pageCount)")
        self.request = request
        load()
    }

    private func load() {
        loadTask?.cancel()
        errorLabel.isHidden = true
        guard let request else { return }
        if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
            show(cached.image)
            return
        }
        spinner.startAnimating()
        loadTask = Task { [weak self] in
            do {
                let image = try await ImagePipeline.shared.image(for: request)
                self?.show(image)
            } catch {
                guard !Task.isCancelled else { return }
                self?.spinner.stopAnimating()
                self?.errorLabel.text = String(localized: "Couldn't load this page.\n\(error.localizedDescription)")
                self?.errorLabel.isHidden = false
            }
        }
    }

    private func show(_ image: UIImage) {
        spinner.stopAnimating()
        imageView.image = image
        accessibilityValue = String(localized: "Loaded")
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.zoomScale == 1 { layoutImage() }
    }

    /// Fits the image in the cell and centres it.
    private func layoutImage() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        let bounds = scrollView.bounds.size
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerImage()
    }

    private func centerImage() {
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
            let location = imageView.convert(point, from: self)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            let origin = CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
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
