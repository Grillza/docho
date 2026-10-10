import SwiftUI

/// The full-screen reader: pages, plus an overlay toggled by a tap in the middle.
struct ReaderView: View {
    @State private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    init(model: ReaderModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = model.loadError {
                ContentUnavailableView {
                    Label("Couldn't Open Chapter", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.loadPageCount() } }
                }
                .foregroundStyle(.white)
            } else if model.isReady && model.pageCount > 0 {
                PagedReaderView(model: model)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            if model.overlayVisible || model.loadError != nil {
                overlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!model.overlayVisible)
        .persistentSystemOverlays(model.overlayVisible ? .automatic : .hidden)
        .task { await model.prepare() }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if model.isReady && model.pageCount > 0 {
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("reader.close")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.seriesName).font(.headline).lineLimit(1)
                Text(model.chapter.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Reading direction", selection: Binding(
                    get: { model.direction },
                    set: { direction in Task { await model.setDirection(direction) } }
                )) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
            } label: {
                Image(systemName: "book.pages")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reading direction")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Laid out in reading direction: in right to left, the next chapter and the slider's end
    /// are on the left.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            chapterButton(previous: true)
            PageSlider(model: model)
            chapterButton(previous: false)
        }
        .environment(\.layoutDirection, model.direction == .rightToLeft ? .rightToLeft : .leftToRight)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The arrows point the way reading goes: in right to left, "next" points left.
    private func chapterButton(previous: Bool) -> some View {
        let target = previous ? model.previousChapter : model.nextChapter
        let leftPointing = previous != (model.direction == .rightToLeft)
        return Button {
            guard let target else { return }
            Task { await model.open(target, atEnd: false) }
        } label: {
            Image(systemName: leftPointing ? "backward.end.fill" : "forward.end.fill")
                .frame(width: 44, height: 44)
        }
        .disabled(target == nil)
        .accessibilityLabel(previous ? "Previous chapter" : "Next chapter")
    }
}

/// Page slider; it inherits the reading direction from the bottom bar, so dragging matches the page order.
private struct PageSlider: View {
    let model: ReaderModel
    @State private var dragging: Double?

    var body: some View {
        let shown = Int(dragging ?? Double(model.page))
        HStack(spacing: 10) {
            Text("\(shown + 1)").monospacedDigit().frame(minWidth: 28)
            if model.pageCount > 1 {
                Slider(
                    value: Binding(get: { dragging ?? Double(model.page) }, set: { dragging = $0.rounded() }),
                    in: 0...Double(model.pageCount - 1),
                    step: 1
                ) { editing in
                    if !editing, let dragging {
                        model.jump(to: Int(dragging))
                        self.dragging = nil
                    }
                }
            }
            Text("\(model.pageCount)").monospacedDigit().frame(minWidth: 28)
        }
        .font(.footnote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page")
        .accessibilityValue("\(shown + 1) of \(model.pageCount)")
        .accessibilityIdentifier("reader.page")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.jump(to: model.page + 1)
            case .decrement: model.jump(to: model.page - 1)
            @unknown default: break
            }
        }
    }
}
