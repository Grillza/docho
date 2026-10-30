import SwiftUI

/// The reader (Mihon's `ReaderActivity`): pages full screen, and a menu toggled by the middle of
/// the screen with the title, the chapter navigator and quick settings.
struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.m3) private var m3
    @State var model: ReaderModel
    @State private var sliderPage: Double = 0
    @State private var showSettings = false

    var body: some View {
        ZStack {
            model.settings.background.color.swiftUI.ignoresSafeArea()
            pages.ignoresSafeArea()
            if !model.overlayVisible, model.settings.showPageNumber, model.pageCount > 0 {
                pageNumber
            }
            if model.overlayVisible {
                menu.transition(.opacity)
            }
        }
        .statusBarHidden(model.settings.fullscreen && !model.overlayVisible)
        .persistentSystemOverlays(model.overlayVisible ? .automatic : .hidden)
        .task { await model.prepare() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = model.settings.keepScreenOn }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: model.page) { _, page in sliderPage = Double(page) }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .m3Sheet(isPresented: $showSettings) { ReaderSettingsSheet(model: model) }
    }

    @ViewBuilder
    private var pages: some View {
        if let error = model.loadError {
            VStack(spacing: 16) {
                Text(error).font(M3Type.bodyMedium).foregroundStyle(.white).multilineTextAlignment(.center)
                FilledButton(title: String(localized: "Retry")) { Task { await model.loadPages() } }
                M3TextButton(title: String(localized: "Close"), color: .white) { dismiss() }
            }
            .padding(32)
        } else if !model.isReady || !model.pagesLoaded {
            ProgressView().tint(.white).controlSize(.large)
                .onTapGesture { withAnimation { model.overlayVisible.toggle() } }
        } else if model.mode.isLongStrip {
            ReaderPagesView<WebtoonReaderController>(model: model)
        } else {
            ReaderPagesView<PagedReaderController>(model: model)
        }
    }

    /// The page number at the bottom while the menu is hidden, outlined so it reads on any page.
    private var pageNumber: some View {
        VStack {
            Spacer()
            Text("\(model.page + 1) / \(model.pageCount)")
                .font(M3Type.labelMedium)
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .shadow(color: .black, radius: 1)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }

    // MARK: Menu

    private var menu: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            VStack(spacing: 8) {
                chapterNavigator
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            AppBarIcon("arrow_back", label: String(localized: "Close")) { dismiss() }
                .foregroundStyle(m3.onSurface)
                .padding(.leading, 4)
                .accessibilityIdentifier("reader.close")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.seriesName).font(M3Type.titleMedium).foregroundStyle(m3.onSurface).lineLimit(1)
                Text(model.chapter.name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant).lineLimit(1)
                    .accessibilityIdentifier("reader.chapter")
            }
            .padding(.leading, 4)
            Spacer(minLength: 8)
            AppBarIcon(model.chapter.bookmark ? "bookmark.fill" : "bookmark", label: model.chapter.bookmark
                ? String(localized: "Remove bookmark") : String(localized: "Bookmark")) {
                Task { await model.toggleBookmark() }
            }
            .foregroundStyle(model.chapter.bookmark ? m3.primary : m3.onSurfaceVariant)
            .padding(.trailing, 4)
        }
        .frame(height: 64)
        .background(m3.surfaceContainer.opacity(0.95).ignoresSafeArea(edges: .top))
    }

    /// Mihon's chapter navigator: previous and next chapter around a pill with the page slider.
    private var chapterNavigator: some View {
        let rightToLeft = model.mode.isRightToLeft
        return HStack(spacing: 8) {
            chapterButton(rightToLeft ? .next : .previous)
            HStack(spacing: 8) {
                Text("\(Int(sliderPage) + 1)")
                    .font(M3Type.labelLarge)
                    .monospacedDigit()
                    .frame(minWidth: 32)
                if model.pageCount > 1 {
                    Slider(value: $sliderPage, in: 0...Double(model.pageCount - 1), step: 1) { editing in
                        if !editing { model.jump(to: Int(sliderPage)) }
                    }
                    .tint(m3.primary)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                    .accessibilityLabel(String(localized: "Page"))
                    .accessibilityValue(String(localized: "\(Int(sliderPage) + 1) of \(model.pageCount)"))
                    .accessibilityIdentifier("reader.slider")
                } else {
                    Spacer()
                }
                Text("\(model.pageCount)")
                    .font(M3Type.labelLarge)
                    .monospacedDigit()
                    .frame(minWidth: 32)
            }
            .foregroundStyle(m3.onSurface)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(Capsule().fill(m3.surfaceContainerHigh.opacity(0.95)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.position")
            chapterButton(rightToLeft ? .previous : .next)
        }
        .padding(.horizontal, 16)
    }

    private func chapterButton(_ direction: ReaderLeave) -> some View {
        let target = direction == .previous ? model.previousChapter : model.nextChapter
        return Button {
            guard let target else { return }
            Task { await model.open(target, atEnd: false) }
        } label: {
            MIcon(direction == .previous ? "skip_previous" : "skip_next")
                .foregroundStyle(target == nil ? m3.onSurface.opacity(0.38) : m3.onSurface)
                .frame(width: 48, height: 48)
                .background(Circle().fill(m3.surfaceContainerHigh.opacity(0.95)))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .accessibilityLabel(direction == .previous ? String(localized: "Previous chapter") : String(localized: "Next chapter"))
    }

    /// Mihon's bottom reader bar: reading mode and settings.
    private var bottomBar: some View {
        HStack {
            Menu {
                ForEach(ReaderMode.allCases) { mode in
                    Button {
                        Task { await model.setMode(mode) }
                    } label: {
                        if model.mode == mode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
            } label: {
                MIcon(model.mode.icon).frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Reading mode"))
            .accessibilityIdentifier("reader.mode")
            Spacer()
            if UIDevice.current.userInterfaceIdiom == .pad, model.mode.isPaged, model.mode != .vertical {
                AppBarIcon("flip_to_back", label: String(localized: "Dual page view")) { model.settings.spreads.toggle() }
                    .foregroundStyle(model.settings.spreads ? m3.primary : m3.onSurface)
                    .accessibilityValue(model.settings.spreads ? String(localized: "On") : String(localized: "Off"))
                Spacer()
            }
            AppBarIcon("settings", label: String(localized: "Settings")) { showSettings = true }
        }
        .foregroundStyle(m3.onSurface)
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(m3.surfaceContainer.opacity(0.95).ignoresSafeArea(edges: .bottom))
    }
}

/// Mihon's reader settings sheet: the mode for this series, then general reader settings.
private struct ReaderSettingsSheet: View {
    @Environment(\.m3) private var m3
    let model: ReaderModel
    @State private var tab = 0

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            M3Tabs(tabs: [0, 1], selection: $tab, title: { [String(localized: "Reading mode"), String(localized: "General")][$0] })
            ScrollView {
                VStack(spacing: 0) {
                    if tab == 0 {
                        PreferenceHeader(title: String(localized: "Reading mode"))
                        ForEach(ReaderMode.allCases) { mode in
                            RadioRow(title: mode.title, selected: model.mode == mode) { Task { await model.setMode(mode) } }
                        }
                        PreferenceHeader(title: model.mode.isLongStrip ? String(localized: "Long strip") : String(localized: "Paged"))
                        if model.mode.isLongStrip {
                            ListPreference(title: String(localized: "Tap zones"), selection: $settings.stripTapZones, options: TapZones.allCases.map { ($0, $0.title) })
                            ListPreference(title: String(localized: "Invert tap zones"), selection: $settings.stripInvert, options: InvertTaps.allCases.map { ($0, $0.title) })
                        } else {
                            ListPreference(title: String(localized: "Tap zones"), selection: $settings.pagedTapZones, options: TapZones.allCases.map { ($0, $0.title) })
                            ListPreference(title: String(localized: "Invert tap zones"), selection: $settings.pagedInvert, options: InvertTaps.allCases.map { ($0, $0.title) })
                            CheckboxRow(title: String(localized: "Dual page view"), isOn: $settings.spreads)
                            CheckboxRow(title: String(localized: "First page alone"), isOn: $settings.coverAlone)
                            CheckboxRow(title: String(localized: "Double tap to zoom"), isOn: $settings.doubleTapZoom)
                        }
                    } else {
                        ListPreference(title: String(localized: "Background color"), selection: $settings.background, options: ReaderBackground.allCases.map { ($0, $0.title) })
                        CheckboxRow(title: String(localized: "Show page number"), isOn: $settings.showPageNumber)
                        CheckboxRow(title: String(localized: "Fullscreen"), isOn: $settings.fullscreen)
                        CheckboxRow(title: String(localized: "Keep screen on"), isOn: $settings.keepScreenOn)
                        CheckboxRow(title: String(localized: "Skip chapters marked read"), isOn: $settings.skipRead)
                        CheckboxRow(title: String(localized: "Animate page transitions"), isOn: $settings.animatePageTransitions)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 16)
        .background(m3.surfaceContainerLow)
    }
}

extension UIColor {
    var swiftUI: Color { Color(uiColor: self) }
}
