import SwiftUI

/// SwiftUI wrapper for `PagedReaderController`, driven by a `ReaderModel`.
struct PagedReaderView: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> PagedReaderController {
        let controller = PagedReaderController()
        context.coordinator.attach(controller, to: model)
        return controller
    }

    func updateUIViewController(_ controller: PagedReaderController, context: Context) {
        let content = PagedReaderContent(
            chapterId: model.chapter.id,
            pageCount: model.pageCount,
            direction: model.direction,
            previousTitle: model.previousChapter?.name,
            nextTitle: model.nextChapter?.name,
            currentTitle: model.chapter.name
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

        func attach(_ controller: PagedReaderController, to model: ReaderModel) {
            controller.pageURL = { [weak model] in model?.pageURL($0) }
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
