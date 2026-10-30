import NukeUI
import SwiftUI

// MARK: - App bars

/// Mihon's top app bar: 64 pt, the title in title-large, a back arrow or nothing, and action
/// icons. It takes the scrolled-under colour when `elevated`.
struct TopAppBar<Actions: View>: View {
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    var title: String
    var subtitle: String?
    var showsBack = false
    var onBack: (() -> Void)?
    var elevated = false
    /// Drawn over content (the series backdrop) until elevated.
    var transparent = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 0) {
            if showsBack || onBack != nil {
                AppBarIcon("arrow_back", label: String(localized: "Back")) {
                    if let onBack { onBack() } else { dismiss() }
                }
                .foregroundStyle(m3.onSurface)
                .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(subtitle == nil ? M3Type.titleLarge : M3Type.titleMedium)
                    .foregroundStyle(m3.onSurface)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .padding(.leading, showsBack || onBack != nil ? 4 : 16)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 0) { actions }
                .foregroundStyle(m3.onSurfaceVariant)
                .padding(.trailing, 4)
        }
        .frame(height: 64)
        .background(elevated ? m3.surfaceContainer : (transparent ? Color.clear : m3.surface))
    }
}

extension TopAppBar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, showsBack: Bool = false, onBack: (() -> Void)? = nil, elevated: Bool = false) {
        self.init(title: title, subtitle: subtitle, showsBack: showsBack, onBack: onBack, elevated: elevated) { EmptyView() }
    }
}

/// A 48 pt icon button, as in Material app bars.
struct AppBarIcon: View {
    let icon: String
    let label: String
    let action: () -> Void

    init(_ icon: String, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MIcon(icon)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(RippleStyle(shape: Circle()))
        .accessibilityLabel(label)
    }
}

/// An app-bar overflow menu (the ⋮ button).
struct OverflowMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            MIcon("more_vert")
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "More options"))
    }
}

/// The press feedback of Material components: a translucent layer over the content.
struct RippleStyle<S: Shape>: ButtonStyle {
    @Environment(\.m3) private var m3
    var shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(m3.onSurface.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == RippleStyle<Rectangle> {
    static var ripple: RippleStyle<Rectangle> { RippleStyle(shape: Rectangle()) }
}

// MARK: - Buttons

struct FilledButton: View {
    @Environment(\.m3) private var m3
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { MIcon(icon, size: 18) }
                Text(title).font(M3Type.labelLarge)
            }
            .padding(.horizontal, icon == nil ? 24 : 16)
            .frame(minHeight: 40)
            .foregroundStyle(m3.onPrimary)
            .background(Capsule().fill(m3.primary))
        }
        .buttonStyle(RippleStyle(shape: Capsule()))
    }
}

struct M3TextButton: View {
    @Environment(\.m3) private var m3
    let title: String
    var color: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(M3Type.labelLarge)
                .foregroundStyle(color ?? m3.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
        }
        .buttonStyle(RippleStyle(shape: Capsule()))
    }
}

/// Mihon's extended floating action button ("Start", "Resume").
struct ExtendedFAB: View {
    @Environment(\.m3) private var m3
    let title: String
    let icon: String
    var expanded = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MIcon(icon)
                if expanded {
                    Text(title).font(M3Type.labelLarge)
                }
            }
            .padding(.horizontal, expanded ? 16 : 16)
            .frame(minWidth: 56, minHeight: 56)
            .foregroundStyle(m3.onPrimaryContainer)
            .background(RoundedRectangle(cornerRadius: 16).fill(m3.primaryContainer))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: 16)))
        .accessibilityLabel(title)
    }
}

// MARK: - Badges and covers

/// Mihon's library badges: small rectangles grouped with rounded outer corners.
struct BadgeGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct TextBadge: View {
    @Environment(\.m3) private var m3
    let text: String
    var color: Color?
    var textColor: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .foregroundStyle(textColor ?? m3.onSecondary)
            .background(color ?? m3.secondary)
    }
}

struct IconBadge: View {
    @Environment(\.m3) private var m3
    let icon: String
    var color: Color?
    var iconColor: Color?

    var body: some View {
        MIcon(icon, size: 12)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .foregroundStyle(iconColor ?? m3.onSecondary)
            .background(color ?? m3.secondary)
    }
}

/// A series cover at Mihon's book ratio (2:3), loaded through the series' source.
struct CoverImage: View {
    @Environment(\.m3) private var m3
    let request: URLRequest?
    var cornerRadius: CGFloat = 4
    var ratio: CGFloat = 2 / 3

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                LazyImage(request: request.map { ImageRequest(urlRequest: $0) }) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        m3.surfaceContainerHighest
                    }
                }
                .processors([.resize(width: 400)])
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}

// MARK: - Preferences (Mihon's settings widgets)

/// A settings row: an optional icon tinted with the primary colour, a 16 pt title and a
/// subtitle, and an optional widget at the end.
struct PreferenceRow<Widget: View>: View {
    @Environment(\.m3) private var m3
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var subtitle: String?
    var icon: String?
    var iconTint: Color?
    var action: (() -> Void)?
    @ViewBuilder var widget: Widget

    var body: some View {
        let row = HStack(spacing: 0) {
            if let icon {
                MIcon(icon)
                    .foregroundStyle(iconTint ?? m3.primary)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(m3.onSurface)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(M3Type.bodySmall)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .lineLimit(10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            widget.padding(.trailing, 16)
        }
        .frame(minHeight: 56)
        .opacity(isEnabled ? 1 : 0.38)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }.buttonStyle(.ripple)
        } else {
            row
        }
    }
}

extension PreferenceRow where Widget == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String? = nil, iconTint: Color? = nil, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, icon: icon, iconTint: iconTint, action: action) { EmptyView() }
    }
}

/// A switch row.
struct SwitchPreference: View {
    var title: String
    var subtitle: String?
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        PreferenceRow(title: title, subtitle: subtitle, icon: icon, action: { isOn.toggle() }) {
            M3Switch(isOn: $isOn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(.isButton)
    }
}

/// A list choice: the current value as the subtitle, the options in a dialog.
struct ListPreference<Value: Hashable>: View {
    var title: String
    var icon: String?
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @State private var choosing = false

    var body: some View {
        PreferenceRow(
            title: title, subtitle: options.first { $0.value == selection }?.title, icon: icon, action: { choosing = true }
        )
        .m3Dialog(isPresented: $choosing, title: title) {
            VStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    RadioRow(title: option.title, selected: option.value == selection) {
                        selection = option.value
                        choosing = false
                    }
                }
            }
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { choosing = false }
        }
    }
}

/// A group title in settings.
struct PreferenceHeader: View {
    @Environment(\.m3) private var m3
    let title: String

    var body: some View {
        Text(title)
            .font(M3Type.bodyMedium)
            .foregroundStyle(m3.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An info note, as at the bottom of some settings screens.
struct InfoPreference: View {
    @Environment(\.m3) private var m3
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MIcon("info", size: 20).foregroundStyle(m3.onSurfaceVariant)
            Text(text).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct M3Divider: View {
    @Environment(\.m3) private var m3

    var body: some View {
        Rectangle().fill(m3.outlineVariant).frame(height: 1)
    }
}

/// Material 3's switch: a 52×32 track with a thumb that grows when on.
struct M3Switch: View {
    @Environment(\.m3) private var m3
    @Environment(\.isEnabled) private var isEnabled
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? m3.primary : m3.surfaceContainerHighest)
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : m3.outline, lineWidth: 2))
            Circle()
                .fill(isOn ? m3.onPrimary : m3.outline)
                .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                .overlay {
                    if isOn { MIcon("check", size: 16).foregroundStyle(m3.onPrimaryContainer) }
                }
                .padding(.horizontal, isOn ? 4 : 8)
        }
        .frame(width: 52, height: 32)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .accessibilityHidden(true)
    }
}

/// A radio row in a dialog.
struct RadioRow: View {
    @Environment(\.m3) private var m3
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                MIcon(selected ? "radio_button_checked" : "radio_button_unchecked")
                    .foregroundStyle(selected ? m3.primary : m3.onSurfaceVariant)
                Text(title).font(M3Type.bodyLarge).foregroundStyle(m3.onSurface)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A checkbox row (sheets and dialogs).
struct CheckboxRow: View {
    @Environment(\.m3) private var m3
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 24) {
                MIcon(isOn ? "check_box.fill" : "check_box_outline_blank")
                    .foregroundStyle(isOn ? m3.primary : m3.onSurfaceVariant)
                Text(title).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityValue(isOn ? String(localized: "Checked") : String(localized: "Unchecked"))
    }
}

/// Mihon's tri-state filter row: off, include (check) or exclude (cross).
struct TriStateRow: View {
    @Environment(\.m3) private var m3
    let title: String
    @Binding var state: ChapterDisplay.TriState
    var enabled = true

    var body: some View {
        Button { state = state.next } label: {
            HStack(spacing: 24) {
                Group {
                    switch state {
                    case .off: MIcon("check_box_outline_blank").foregroundStyle(m3.onSurfaceVariant)
                    case .include: MIcon("check_box.fill").foregroundStyle(m3.primary)
                    case .exclude: MIcon("disabled_by_default.fill").foregroundStyle(m3.primary)
                    }
                }
                Text(title).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
    }
}

/// A sort row: an arrow on the selected option shows the direction.
struct SortRow: View {
    @Environment(\.m3) private var m3
    let title: String
    let selected: Bool
    let ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Group {
                    if selected {
                        MIcon(ascending ? "arrow_upward" : "arrow_downward").foregroundStyle(m3.primary)
                    } else {
                        Color.clear.frame(width: 24, height: 24)
                    }
                }
                Text(title).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Chips and tabs

/// A suggestion chip (genres on the series screen).
struct M3Chip: View {
    @Environment(\.m3) private var m3
    let text: String
    var selected = false
    var action: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 8) {
            if selected { MIcon("check", size: 18) }
            Text(text).font(M3Type.labelLarge).lineLimit(1)
        }
        .padding(.horizontal, selected ? 8 : 16)
        .frame(height: 32)
        .foregroundStyle(selected ? m3.onSecondaryContainer : m3.onSurfaceVariant)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? m3.secondaryContainer : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.clear : m3.outline, lineWidth: 1))
        if let action {
            Button(action: action) { label }.buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: 8)))
        } else {
            label
        }
    }
}

/// Material's tab row: labels with an indicator under the selected one.
struct M3Tabs<Tab: Hashable>: View {
    @Environment(\.m3) private var m3
    let tabs: [Tab]
    @Binding var selection: Tab
    var scrollable = false
    let title: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }

    var body: some View {
        VStack(spacing: 0) {
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) { items }
                            .padding(.horizontal, 52 - 16)
                    }
                    .onChange(of: selection) { _, tab in withAnimation { proxy.scrollTo(tab, anchor: .center) } }
                }
            } else {
                HStack(spacing: 0) { items }
            }
            M3Divider()
        }
        .background(m3.surface)
    }

    private var items: some View {
        ForEach(tabs, id: \.self) { tab in
            let selected = tab == selection
            Button { selection = tab } label: {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text(title(tab))
                            .font(M3Type.titleSmall)
                            .lineLimit(1)
                        if let badge = badge(tab) {
                            Text(badge)
                                .font(M3Type.labelSmall)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .foregroundStyle(selected ? m3.onPrimary : m3.onSurfaceVariant)
                                .background(Capsule().fill(selected ? m3.primary : m3.surfaceContainerHighest))
                        }
                    }
                    .foregroundStyle(selected ? m3.primary : m3.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(selected ? m3.primary : .clear)
                        .frame(height: 3)
                        .padding(.horizontal, scrollable ? 16 : 24)
                }
                .frame(height: 48)
                .frame(maxWidth: scrollable ? nil : .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.ripple)
            .id(tab)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
}

// MARK: - Empty, loading and error screens

/// Mihon's empty screen: a kaomoji face over a message, with optional actions.
struct EmptyScreen<Actions: View>: View {
    @Environment(\.m3) private var m3
    let message: String
    @ViewBuilder var actions: Actions
    @State private var face = EmptyScreenFaces.random

    var body: some View {
        VStack(spacing: 16) {
            Text(face)
                .font(.system(size: 45))
                .foregroundStyle(m3.onSurfaceVariant)
                .accessibilityHidden(true)
            Text(message)
                .font(M3Type.bodyMedium)
                .foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyScreen where Actions == EmptyView {
    init(message: String) {
        self.init(message: message) { EmptyView() }
    }
}

enum EmptyScreenFaces {
    static let all = ["(･o･;)", "Σ(ಠ_ಠ)", "ಥ_ಥ", "(˘･_･˘)", "(；￣Д￣)", "(･Д･。"]
    static var random: String { all.randomElement() ?? all[0] }
}

struct LoadingScreen: View {
    @Environment(\.m3) private var m3

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(m3.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dialogs and sheets

/// Material's alert dialog: a 28 pt rounded card with a title, content and text buttons.
struct M3DialogModifier<DialogContent: View, Buttons: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String?
    @ViewBuilder var dialogContent: DialogContent
    @ViewBuilder var buttons: Buttons

    /// Follows `isPresented` without the cover's slide, so the card fades in like Android's.
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $presented, onDismiss: { isPresented = false }) {
                M3DialogCard(title: title, onDismiss: { isPresented = false }, content: { dialogContent }, buttons: { buttons })
                    .presentationBackground(.clear)
            }
            .onChange(of: isPresented, initial: true) { _, shown in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { presented = shown }
            }
    }
}

struct M3DialogCard<Content: View, Buttons: View>: View {
    @Environment(\.m3) private var m3
    let title: String?
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                if let title {
                    Text(title)
                        .font(M3Type.headlineSmall)
                        .foregroundStyle(m3.onSurface)
                        .padding(.horizontal, 24)
                        .accessibilityAddTraits(.isHeader)
                }
                ScrollView {
                    content
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack(spacing: 8) {
                    Spacer()
                    buttons
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: 560)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 28).fill(m3.surfaceContainerHigh))
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .scaleEffect(shown ? 1 : 0.9)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
    }
}

extension View {
    func m3Dialog<Content: View, Buttons: View>(
        isPresented: Binding<Bool>,
        title: String?,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        modifier(M3DialogModifier(isPresented: isPresented, title: title, dialogContent: content, buttons: buttons))
    }

    /// A Mihon-style bottom sheet: surface-container-low, rounded top corners and a drag handle.
    func m3Sheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) {
            M3SheetContainer(content: content)
        }
    }
}

struct M3SheetContainer<Content: View>: View {
    @Environment(\.m3) private var m3
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.m3, m3)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(m3.surfaceContainerLow)
            .presentationCornerRadius(28)
    }
}

/// Mihon's search field in the app bar.
struct AppBarSearchField: View {
    @Environment(\.m3) private var m3
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(text: $text) {
            Text(placeholder).foregroundStyle(m3.onSurfaceVariant)
        }
        .font(M3Type.bodyLarge)
        .foregroundStyle(m3.onSurface)
        .focused($focused)
        .submitLabel(.search)
        .onSubmit(onSubmit)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onAppear { focused = true }
    }
}

/// An outlined text field (server settings).
struct M3TextField: View {
    @Environment(\.m3) private var m3
    let label: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var supporting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if secure {
                    SecureField(label, text: $text)
                } else {
                    TextField(label, text: $text)
                }
            }
            .font(M3Type.bodyLarge)
            .foregroundStyle(m3.onSurface)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(M3Type.bodySmall)
                    .foregroundStyle(m3.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .background(m3.surface)
                    .offset(x: 12, y: -8)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(m3.outline, lineWidth: 1))
            if let supporting {
                Text(supporting).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Dates

enum RelativeDates {
    /// "Today", "Yesterday", "n days ago" (within a week) or the date, as Mihon's relative
    /// timestamps; the date alone when they're off.
    static func label(_ date: Date, relative: Bool, format: String) -> String {
        let calendar = Calendar.current
        if relative {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
            switch days {
            case 0: return String(localized: "Today")
            case 1: return String(localized: "Yesterday")
            case 2..<7: return String(localized: "\(days) days ago")
            default: break
            }
        }
        if format.isEmpty { return date.formatted(date: .numeric, time: .omitted) }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// MARK: - Text

enum HTMLText {
    /// A summary as plain text: servers such as Kavita send HTML, which Mihon renders. Line
    /// breaks and paragraphs become new lines, tags go, and entities are decoded.
    static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var text = html
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</p>\s*"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&amp;": "&"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
