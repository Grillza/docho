import Nuke
import UIKit

/// What a reader controller shows: one chapter's pages between two transition pages.
struct ReaderContent: Equatable {
    var chapterId: Int
    var pageCount: Int
    var rightToLeft: Bool
    /// Paged only: two pages per screen while the view is wider than it is tall.
    var spreads: Bool
    var coverAlone: Bool
    var previousTitle: String?
    var nextTitle: String?
    var currentTitle: String
}

/// Horizontal paging over a chapter. Each page zooms on its own (pinch or double-tap) and the
/// zoom resets when the page changes. Right to left flips the layout, so page 1 is on the right.
/// With spreads on and a landscape view, pages are shown in pairs (see `PageSpreads`).
///
/// Taps: the outer thirds turn pages (by reading direction), the middle toggles the overlay.
/// Moving past a transition page, by tap or swipe, opens the neighbouring chapter.
final class PagedReaderController: UIViewController, ReaderController {
    enum Item: Hashable {
        case leading
        /// One page, or two in a spread.
        case pages([Int])
        case trailing
    }

    var onPageShown: (Int) -> Void = { _ in }
    var onToggleOverlay: () -> Void = {}
    var onLeave: (ReaderLeave) -> Void = { _ in }
    var pageURL: (Int) -> URL? = { _ in nil }

    private(set) var content: ReaderContent?
    private var items: [Item] = []
    private var pendingIndex: Int?
    private var currentIndex = 0
    private var dragStartIndex = 0
    /// Pages whose image turned out wider than tall; they're never paired.
    private var widePages: Set<Int> = []
    private var showsSpreads = false

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
            if shouldShowSpreads != showsSpreads {
                rebuildItems(keeping: currentPages.first)
            }
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

    /// Shows `content`, starting at `page`. A new chapter, direction or spread setting reloads everything.
    func show(_ content: ReaderContent, page: Int) {
        let newChapter = content.chapterId != self.content?.chapterId || content.pageCount != self.content?.pageCount
        let reload = newChapter
            || content.rightToLeft != self.content?.rightToLeft
            || content.spreads != self.content?.spreads
            || content.coverAlone != self.content?.coverAlone
        self.content = content
        guard reload else {
            reconfigureTransitions()
            return
        }
        if newChapter { widePages = [] }
        collectionView.semanticContentAttribute = content.rightToLeft ? .forceRightToLeft : .forceLeftToRight
        rebuildItems(keeping: page)
        view.setNeedsLayout()
    }

    private var shouldShowSpreads: Bool {
        guard let content, content.spreads else { return false }
        return view.bounds.width > view.bounds.height
    }

    /// Lays the pages out again (single or paired), staying on the item that holds `page`.
    private func rebuildItems(keeping page: Int?) {
        guard let content else { return }
        showsSpreads = shouldShowSpreads
        let groups = showsSpreads
            ? PageSpreads.pair(pageCount: content.pageCount, wide: widePages, coverAlone: content.coverAlone)
            : (0..<content.pageCount).map { [$0] }
        items = [.leading] + groups.map(Item.pages) + [.trailing]
        collectionView.reloadData()
        currentIndex = page.flatMap(index(of:)) ?? min(1, items.count - 1)
        pendingIndex = currentIndex
    }

    private func index(of page: Int) -> Int? {
        items.firstIndex { item in
            if case .pages(let pages) = item { pages.contains(page) } else { false }
        }
    }

    private var currentPages: [Int] {
        guard items.indices.contains(currentIndex), case .pages(let pages) = items[currentIndex] else { return [] }
        return pages
    }

    /// A page turned out wide: if it was paired, pair again without it.
    private func imageLoaded(page: Int, size: CGSize) {
        guard size.width > size.height, !widePages.contains(page) else { return }
        widePages.insert(page)
        guard showsSpreads, let index = index(of: page), case .pages(let pages) = items[index], pages.count > 1 else { return }
        rebuildItems(keeping: currentPages.first)
        view.setNeedsLayout()
    }

    func go(toPage page: Int, animated: Bool) {
        guard let index = index(of: page) else { return }
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
        if case .pages(let pages) = items[index], let last = pages.last {
            // Every page of a spread is on screen, so the later one counts.
            onPageShown(last)
            prefetch(around: last)
        }
        if changed {
            UIAccessibility.post(notification: .pageScrolled, argument: accessibilityPosition)
        }
    }

    private var accessibilityPosition: String {
        guard let content, let first = currentPages.first, let last = currentPages.last else { return "" }
        return first == last
            ? String(localized: "Page \(first + 1) of \(content.pageCount)")
            : String(localized: "Pages \(first + 1)–\(last + 1) of \(content.pageCount)")
    }

    private func reconfigureTransitions() {
        let paths = [0, items.count - 1].filter { $0 >= 0 }.map { IndexPath(item: $0, section: 0) }
        collectionView.reconfigureItems(at: paths)
    }

    // MARK: Images

    /// Pages are downsampled to twice their share of the view, enough for zooming without
    /// holding full-resolution scans in memory.
    private func request(for page: Int, share: Int = 1) -> ImageRequest? {
        guard let url = pageURL(page) else { return nil }
        let scale = view.window?.windowScene?.screen.scale ?? 2
        let width = view.bounds.width / CGFloat(max(share, 1))
        let size = CGSize(width: width * scale * 2, height: view.bounds.height * scale * 2)
        return ImageRequest(
            url: url,
            processors: [.resize(size: size, unit: .pixels, contentMode: .aspectFit, upscale: false)],
            // Downloaded pages are already on disk.
            options: url.isFileURL ? [.disableDiskCacheWrites] : []
        )
    }

    /// Keeps the three pages either side of `page` loading.
    private func prefetch(around page: Int) {
        guard let content else { return }
        let range = max(0, page - 3)...min(content.pageCount - 1, page + 3)
        let share = showsSpreads ? 2 : 1
        let requests = range.filter { $0 != page }.compactMap { request(for: $0, share: share) }
        prefetcher.stopPrefetching(with: prefetched)
        prefetcher.startPrefetching(with: requests)
        prefetched = requests
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// Arrow keys turn pages the way they point (so in right to left, ← is the next page);
    /// space goes on and shift-space back.
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(leftKey)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(rightKey)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextKey)),
            UIKeyCommand(input: " ", modifierFlags: .shift, action: #selector(previousKey)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func leftKey() { step(content?.rightToLeft == true ? 1 : -1) }
    @objc private func rightKey() { step(content?.rightToLeft == true ? -1 : 1) }
    @objc private func nextKey() { step(1) }
    @objc private func previousKey() { step(-1) }

    // MARK: Gestures

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let position = gesture.location(in: view).x / max(view.bounds.width, 1)
        let rightToLeft = content?.rightToLeft == true
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
        case .pages(let pages):
            // swiftlint:disable:next force_cast
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageCell.reuseIdentifier, for: indexPath) as! PageCell
            cell.onImageSize = { [weak self] page, size in
                // Not while the collection view is asking for cells (cached images arrive at once).
                Task { @MainActor in self?.imageLoaded(page: page, size: size) }
            }
            cell.configure(
                requests: pages.map { request(for: $0, share: pages.count) }, pages: pages,
                pageCount: content?.pageCount ?? 0, rightToLeft: content?.rightToLeft == true
            )
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
        let forward = content?.rightToLeft == true ? translation > 0 : translation < 0
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
