import Nuke
import UIKit

/// Vertical, continuous reading: every page at full width, one after another, between two
/// transition pages. Pinch or double-tap zooms the whole strip.
///
/// Page heights aren't known until an image loads, so pages start at a guessed height. Images
/// near the reading position are loaded ahead, and when one turns out taller or shorter above
/// the reading position, the scroll position moves with it so what's on screen stays put.
///
/// Taps: the top third scrolls back, the bottom third scrolls on (past either end, to the
/// neighbouring chapter), the middle toggles the overlay. Pulling past an end does the same.
final class WebtoonReaderController: UIViewController, ReaderController {
    var onPageShown: (Int) -> Void = { _ in }
    var onToggleOverlay: () -> Void = {}
    var onLeave: (ReaderLeave) -> Void = { _ in }
    var pageRequest: (Int) -> URLRequest? = { _ in nil }

    private(set) var content: ReaderContent?
    private var pageCount = 0
    /// Height divided by width, per page, once known.
    private var aspects: [Int: CGFloat] = [:]
    private static let guessedAspect: CGFloat = 1.5
    private static let pullToLeave: CGFloat = 80

    private let zoomView = UIScrollView()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var pendingPage: Int?
    private var currentPage = -1
    private var layoutWidth: CGFloat = 0
    private var loads: [Int: Task<Void, Never>] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        zoomView.frame = view.bounds
        zoomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomView.minimumZoomScale = 1
        zoomView.maximumZoomScale = 3
        zoomView.delegate = self
        zoomView.showsHorizontalScrollIndicator = false
        zoomView.showsVerticalScrollIndicator = false
        zoomView.contentInsetAdjustmentBehavior = .never
        view.addSubview(zoomView)

        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        collectionView.backgroundColor = .black
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(WebtoonPageCell.self, forCellWithReuseIdentifier: WebtoonPageCell.reuseIdentifier)
        collectionView.register(TransitionCell.self, forCellWithReuseIdentifier: TransitionCell.reuseIdentifier)
        collectionView.accessibilityIdentifier = "reader.pages"
        zoomView.addSubview(collectionView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        collectionView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        singleTap.require(toFail: doubleTap)
        collectionView.addGestureRecognizer(singleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard zoomView.zoomScale == 1 else { return }
        collectionView.frame = zoomView.bounds
        zoomView.contentSize = zoomView.bounds.size
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        if width != layoutWidth {
            // A new width changes every height; stay on the same page.
            layoutWidth = width
            pendingPage = pendingPage ?? max(currentPage, 0)
            layout.invalidateLayout()
        }
        if let page = pendingPage {
            pendingPage = nil
            collectionView.layoutIfNeeded()
            scroll(toPage: page)
        }
    }

    func show(_ content: ReaderContent, page: Int) {
        let reload = content.chapterId != self.content?.chapterId || content.pageCount != self.content?.pageCount
        if content.gap != self.content?.gap {
            layout.minimumLineSpacing = content.gap
            layout.invalidateLayout()
        }
        self.content = content
        view.backgroundColor = content.background.color
        collectionView.backgroundColor = content.background.color
        guard reload else {
            collectionView.reconfigureItems(at: [IndexPath(item: 0, section: 0), IndexPath(item: pageCount + 1, section: 0)])
            return
        }
        loads.values.forEach { $0.cancel() }
        loads = [:]
        aspects = [:]
        pageCount = content.pageCount
        currentPage = -1
        zoomView.setZoomScale(1, animated: false)
        collectionView.reloadData()
        pendingPage = page
        view.setNeedsLayout()
    }

    func go(toPage page: Int, animated: Bool) {
        guard (0..<pageCount).contains(page) else { return }
        scroll(toPage: page)
    }

    /// Puts the top of `page` at the top of the screen.
    private func scroll(toPage page: Int) {
        guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: page + 1, section: 0))?.frame else { return }
        let maxOffset = max(collectionView.contentSize.height - collectionView.bounds.height, 0)
        collectionView.contentOffset.y = min(frame.minY, maxOffset)
        loadAround(page)
        updateCurrentPage()
    }

    private var maxOffset: CGFloat {
        max(collectionView.contentSize.height - collectionView.bounds.height, 0)
    }

    /// The page at the middle of the screen; the last one once the end is in view.
    private func updateCurrentPage() {
        guard pageCount > 0 else { return }
        let bounds = collectionView.bounds
        var page: Int
        if bounds.minY >= maxOffset - 1 {
            page = pageCount - 1
        } else if let item = collectionView.indexPathForItem(at: CGPoint(x: bounds.midX, y: bounds.midY))?.item {
            page = min(max(item - 1, 0), pageCount - 1)
        } else {
            return
        }
        // The trailing transition can show before the last page reaches the middle.
        if page < pageCount - 1, bounds.maxY >= collectionView.contentSize.height - transitionHeight {
            page = pageCount - 1
        }
        guard page != currentPage else { return }
        currentPage = page
        onPageShown(page)
        loadAround(page)
        UIAccessibility.post(notification: .pageScrolled, argument: String(localized: "Page \(page + 1) of \(pageCount)"))
    }

    // MARK: Images

    /// Strips are scaled to the screen width (never up), which keeps very long ones manageable.
    private func request(for page: Int) -> ImageRequest? {
        guard let urlRequest = pageRequest(page) else { return nil }
        let scale = view.window?.windowScene?.screen.scale ?? 2
        return ImageRequest(
            urlRequest: urlRequest,
            processors: [.resize(width: view.bounds.width * scale, unit: .pixels, upscale: false)],
            // Downloaded pages are already on disk.
            options: urlRequest.url?.isFileURL == true ? [.disableDiskCacheWrites] : []
        )
    }

    /// Loads the three pages either side ahead of time, so their heights are known before
    /// they're on screen.
    private func loadAround(_ page: Int) {
        let range = max(0, page - 3)...min(pageCount - 1, page + 3)
        for (loading, task) in loads where !range.contains(loading) {
            task.cancel()
            loads[loading] = nil
        }
        for nearby in range where loads[nearby] == nil && aspects[nearby] == nil {
            guard let request = request(for: nearby) else { continue }
            loads[nearby] = Task { [weak self] in
                guard let image = try? await ImagePipeline.shared.image(for: request) else { return }
                self?.imageLoaded(page: nearby, size: image.size)
            }
        }
    }

    /// Sets the page's real height. If the page starts above the screen's top, the scroll
    /// position moves by the part of the change above the top, so the content on screen stays.
    private func imageLoaded(page: Int, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = size.height / size.width
        guard abs((aspects[page] ?? Self.guessedAspect) - aspect) > 0.001 else {
            aspects[page] = aspect
            return
        }
        let indexPath = IndexPath(item: page + 1, section: 0)
        let old = layout.layoutAttributesForItem(at: indexPath)?.frame ?? .zero
        aspects[page] = aspect
        let newHeight = collectionView.bounds.width * aspect
        let top = collectionView.contentOffset.y
        var shift: CGFloat = 0
        if old.maxY <= top {
            shift = newHeight - old.height
        } else if old.minY < top, old.height > 0 {
            shift = (newHeight - old.height) * (top - old.minY) / old.height
        }
        UIView.performWithoutAnimation {
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if shift != 0 { collectionView.contentOffset.y += shift }
        }
    }

    private var transitionHeight: CGFloat { max(collectionView.bounds.height * 0.4, 200) }

    // MARK: Gestures

    /// Taps follow the long strip's tap zones from Settings → Reader (L shaped by default).
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let point = CGPoint(x: location.x / max(view.bounds.width, 1), y: location.y / max(view.bounds.height, 1))
        switch (content?.tapZones ?? .lShaped).action(at: point, invert: content?.invertTaps ?? .none) {
        case .previous, .left: scrollBy(screens: -1)
        case .next, .right: scrollBy(screens: 1)
        case .menu: onToggleOverlay()
        }
    }

    /// Scrolls three quarters of a screen down (or up), or past an end into the next chapter.
    private func scrollBy(screens direction: Int) {
        let step = collectionView.bounds.height * 0.75
        let offset = collectionView.contentOffset.y
        if direction < 0 {
            if offset <= 1 {
                onLeave(.previous)
            } else {
                collectionView.setContentOffset(CGPoint(x: 0, y: max(offset - step, 0)), animated: true)
            }
        } else if offset >= maxOffset - 1 {
            onLeave(.next)
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: min(offset + step, maxOffset)), animated: true)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// ↓ and space scroll on, ↑ and shift-space back.
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextKey)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousKey)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextKey)),
            UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(previousKey)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func nextKey() { scrollBy(screens: 1) }
    @objc private func previousKey() { scrollBy(screens: -1) }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard content?.doubleTapZoom != false else { return }
        if zoomView.zoomScale > 1 {
            zoomView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: collectionView)
            let scale: CGFloat = 2
            let size = CGSize(width: zoomView.bounds.width / scale, height: zoomView.bounds.height / scale)
            let visible = CGPoint(x: point.x, y: point.y - collectionView.contentOffset.y)
            let origin = CGPoint(x: visible.x - size.width / 2, y: visible.y - size.height / 2)
            zoomView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    deinit {
        for task in loads.values { task.cancel() }
    }
}

extension WebtoonReaderController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pageCount + 2
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = indexPath.item
        guard item > 0, item <= pageCount else {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TransitionCell.reuseIdentifier, for: indexPath
            ) as! TransitionCell // swiftlint:disable:this force_cast
            configureTransition(cell, leading: item == 0)
            return cell
        }
        let page = item - 1
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: WebtoonPageCell.reuseIdentifier, for: indexPath
        ) as! WebtoonPageCell // swiftlint:disable:this force_cast
        cell.onImageSize = { [weak self] size in
            // Not while the collection view is asking for cells (cached images arrive at once).
            Task { @MainActor in self?.imageLoaded(page: page, size: size) }
        }
        cell.configure(request: request(for: page), page: page, pageCount: pageCount)
        return cell
    }

    private func configureTransition(_ cell: TransitionCell, leading: Bool) {
        guard let content else { return }
        if leading {
            cell.configure(
                current: String(localized: "Current: \(content.currentTitle)"),
                other: content.previousTitle.map { String(localized: "Previous: \($0)") },
                none: String(localized: "There's no previous chapter.")
            )
        } else {
            cell.configure(
                current: String(localized: "Finished: \(content.currentTitle)"),
                other: content.nextTitle.map { String(localized: "Next: \($0)") },
                none: String(localized: "There's no next chapter.")
            )
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        let item = indexPath.item
        guard item > 0, item <= pageCount else { return CGSize(width: width, height: transitionHeight) }
        return CGSize(width: width, height: (width * (aspects[item - 1] ?? Self.guessedAspect)).rounded())
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, pendingPage == nil else { return }
        updateCurrentPage()
    }

    /// Pulling well past either end opens the neighbouring chapter.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === collectionView else { return }
        let offset = scrollView.contentOffset.y
        if offset > maxOffset + Self.pullToLeave {
            onLeave(.next)
        } else if offset < -Self.pullToLeave {
            onLeave(.previous)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === zoomView ? collectionView : nil
    }
}
