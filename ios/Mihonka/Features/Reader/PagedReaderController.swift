import Nuke
import UIKit

/// What the paged reader shows: one chapter's pages between two transition pages.
struct PagedReaderContent: Equatable {
    var chapterId: Int
    var pageCount: Int
    var direction: ReadingDirection
    var previousTitle: String?
    var nextTitle: String?
    var currentTitle: String
}

/// Horizontal paging over a chapter. Each page zooms on its own (pinch or double-tap) and the
/// zoom resets when the page changes. Right to left flips the layout, so page 1 is on the right.
///
/// Taps: the outer thirds turn pages (by reading direction), the middle toggles the overlay.
/// Moving past a transition page, by tap or swipe, opens the neighbouring chapter.
final class PagedReaderController: UIViewController {
    enum Item: Hashable {
        case leading
        case page(Int)
        case trailing
    }

    enum Leave {
        case previous
        case next
    }

    var onPageShown: (Int) -> Void = { _ in }
    var onToggleOverlay: () -> Void = {}
    var onLeave: (Leave) -> Void = { _ in }
    var pageURL: (Int) -> URL? = { _ in nil }

    private(set) var content: PagedReaderContent?
    private var items: [Item] = []
    private var pendingIndex: Int?
    private var currentIndex = 0
    private var dragStartIndex = 0

    private let layout = FlippingFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let prefetcher = ImagePrefetcher(pipeline: .shared)
    private var prefetched: [ImageRequest] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PageCell.self, forCellWithReuseIdentifier: PageCell.reuseIdentifier)
        collectionView.register(TransitionCell.self, forCellWithReuseIdentifier: TransitionCell.reuseIdentifier)
        collectionView.accessibilityIdentifier = "reader.pages"
        view.addSubview(collectionView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        collectionView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        singleTap.require(toFail: doubleTap)
        collectionView.addGestureRecognizer(singleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if layout.itemSize != size, size.width > 0 {
            layout.itemSize = size
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            pendingIndex = pendingIndex ?? currentIndex
        }
        if let index = pendingIndex, items.indices.contains(index), size.width > 0 {
            pendingIndex = nil
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
            settle(on: index)
        }
    }

    /// Shows `content`, starting at `page`. A new chapter or direction reloads everything.
    func show(_ content: PagedReaderContent, page: Int) {
        let reload = content.chapterId != self.content?.chapterId
            || content.pageCount != self.content?.pageCount
            || content.direction != self.content?.direction
        self.content = content
        guard reload else {
            reconfigureTransitions()
            return
        }
        collectionView.semanticContentAttribute = content.direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        items = [.leading] + (0..<content.pageCount).map(Item.page) + [.trailing]
        collectionView.reloadData()
        currentIndex = min(page + 1, items.count - 1)
        pendingIndex = currentIndex
        view.setNeedsLayout()
    }

    func go(toPage page: Int, animated: Bool) {
        guard let index = items.firstIndex(of: .page(page)) else { return }
        scroll(to: index, animated: animated)
    }

    private func scroll(to index: Int, animated: Bool) {
        guard items.indices.contains(index) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: animated)
        if !animated { settle(on: index) }
    }

    /// Moves one item in reading order, or leaves the chapter from a transition page.
    private func step(_ delta: Int) {
        let target = currentIndex + delta
        if target < 0 {
            onLeave(.previous)
        } else if target >= items.count {
            onLeave(.next)
        } else {
            scroll(to: target, animated: true)
        }
    }

    private func settle(on index: Int) {
        guard items.indices.contains(index) else { return }
        let changed = index != currentIndex
        currentIndex = index
        let others = collectionView.visibleCells.filter { collectionView.indexPath(for: $0)?.item != index }
        for case let cell as PageCell in others {
            cell.resetZoom()
        }
        if case .page(let page) = items[index] {
            onPageShown(page)
            prefetch(around: page)
        }
        if changed {
            UIAccessibility.post(notification: .pageScrolled, argument: accessibilityPosition)
        }
    }

    private var accessibilityPosition: String {
        guard case .page(let page) = items[currentIndex], let content else { return "" }
        return String(localized: "Page \(page + 1) of \(content.pageCount)")
    }

    private func reconfigureTransitions() {
        let paths = [0, items.count - 1].filter { $0 >= 0 }.map { IndexPath(item: $0, section: 0) }
        collectionView.reconfigureItems(at: paths)
    }

    // MARK: Images

    /// Pages are downsampled to twice the view size, enough for zooming without holding
    /// full-resolution scans in memory.
    private func request(for page: Int) -> ImageRequest? {
        guard let url = pageURL(page) else { return nil }
        let scale = view.window?.windowScene?.screen.scale ?? 2
        let size = CGSize(width: view.bounds.width * scale * 2, height: view.bounds.height * scale * 2)
        return ImageRequest(
            url: url,
            processors: [.resize(size: size, unit: .pixels, contentMode: .aspectFit, upscale: false)]
        )
    }

    /// Keeps the three pages either side of `page` loading.
    private func prefetch(around page: Int) {
        guard let content else { return }
        let range = max(0, page - 3)...min(content.pageCount - 1, page + 3)
        let requests = range.filter { $0 != page }.compactMap(request(for:))
        prefetcher.stopPrefetching(with: prefetched)
        prefetcher.startPrefetching(with: requests)
        prefetched = requests
    }

    // MARK: Gestures

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let position = gesture.location(in: view).x / max(view.bounds.width, 1)
        let rightToLeft = content?.direction == .rightToLeft
        switch position {
        case ..<(1 / 3): step(rightToLeft ? 1 : -1)
        case (2 / 3)...: step(rightToLeft ? -1 : 1)
        default: onToggleOverlay()
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let cell = collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? PageCell
        cell?.toggleZoom(at: gesture.location(in: cell))
    }

    deinit {
        prefetcher.stopPrefetching()
    }
}

extension PagedReaderController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch items[indexPath.item] {
        case .page(let page):
            // swiftlint:disable:next force_cast
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageCell.reuseIdentifier, for: indexPath) as! PageCell
            cell.configure(request: request(for: page), page: page, pageCount: content?.pageCount ?? 0)
            return cell
        case .leading, .trailing:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TransitionCell.reuseIdentifier, for: indexPath
            ) as! TransitionCell // swiftlint:disable:this force_cast
            configureTransition(cell, item: items[indexPath.item])
            return cell
        }
    }

    private func configureTransition(_ cell: TransitionCell, item: Item) {
        guard let content else { return }
        if item == .leading {
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

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartIndex = currentIndex
    }

    /// A swipe past a transition page leaves the chapter (paging can't scroll beyond the ends).
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let translation = scrollView.panGestureRecognizer.translation(in: view).x
        let forward = content?.direction == .rightToLeft ? translation > 0 : translation < 0
        guard abs(translation) > 60 else { return }
        if dragStartIndex == items.count - 1, forward {
            onLeave(.next)
        } else if dragStartIndex == 0, !forward {
            onLeave(.previous)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleOnVisibleItem()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleOnVisibleItem()
    }

    private func settleOnVisibleItem() {
        let center = CGPoint(x: collectionView.bounds.midX, y: collectionView.bounds.midY)
        if let index = collectionView.indexPathForItem(at: center)?.item {
            settle(on: index)
        }
    }
}

/// Lays item 0 out on the right when the collection view is right to left.
final class FlippingFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}
