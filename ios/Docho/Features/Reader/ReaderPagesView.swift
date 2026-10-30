import SwiftUI
import UIKit

/// Leaving the chapter from one of its ends.
enum ReaderLeave {
    case previous
    case next
}

/// What `ReaderPagesView` needs from a UIKit reader: paged or webtoon.
@MainActor
protocol ReaderController: UIViewController {
    var onPageShown: (Int) -> Void { get set }
    var onToggleOverlay: () -> Void { get set }
    var onLeave: (ReaderLeave) -> Void { get set }
    var pageRequest: (Int) -> URLRequest? { get set }
    var content: ReaderContent? { get }

    init()
    func show(_ content: ReaderContent, page: Int)
    func go(toPage page: Int, animated: Bool)
}

/// SwiftUI wrapper for a reader controller, driven by a `ReaderModel`.
struct ReaderPagesView<Controller: ReaderController>: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        context.coordinator.attach(controller, to: model)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let content = ReaderContent(
            chapterId: model.chapter.id,
            pageCount: model.pageCount,
            rightToLeft: model.mode.isRightToLeft,
            spreads: model.settings.spreads,
            coverAlone: model.settings.coverAlone,
            previousTitle: model.previousChapter?.name,
            nextTitle: model.nextChapter?.name,
            currentTitle: model.chapter.name,
            vertical: model.mode == .vertical,
            tapZones: model.mode.isLongStrip ? model.settings.stripTapZones : model.settings.pagedTapZones,
            invertTaps: model.mode.isLongStrip ? model.settings.stripInvert : model.settings.pagedInvert,
            background: model.settings.background,
            doubleTapZoom: model.settings.doubleTapZoom,
            animate: model.settings.animatePageTransitions,
            gap: model.mode == .webtoonGaps ? 16 : 0
        )
        if controller.content != content {
            controller.show(content, page: model.page)
        }
        if let jump = model.jump, jump != context.coordinator.lastJump {
            context.coordinator.lastJump = jump
            controller.go(toPage: jump.page, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastJump: ReaderModel.PageJump?

        func attach(_ controller: Controller, to model: ReaderModel) {
            controller.pageRequest = { [weak model] in model?.pageRequest($0) }
            controller.onPageShown = { [weak model] page in
                Task { await model?.pageShown(page) }
            }
            controller.onToggleOverlay = { [weak model] in
                withAnimation(.easeInOut(duration: 0.2)) { model?.overlayVisible.toggle() }
            }
            controller.onLeave = { [weak model] leave in
                guard let model else { return }
                switch leave {
                case .previous:
                    if let previous = model.previousChapter { Task { await model.open(previous, atEnd: true) } }
                case .next:
                    if let next = model.nextChapter { Task { await model.open(next, atEnd: false) } }
                }
            }
        }
    }
}
