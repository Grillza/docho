import SwiftUI

/// Android's Custom themes screen (0.25): up to five themes, tap one to use it, edit or delete.
struct CustomThemesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var editing: EditorTarget?
    @State private var deleting: Int?

    struct EditorTarget: Identifiable {
        let index: Int?
        var id: Int { index ?? -1 }
    }

    var body: some View {
        let preferences = app.preferences
        let themes = preferences.customThemes
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Custom themes"), showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    Text(info(count: themes.count))
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(themes.enumerated()), id: \.element.id) { index, theme in
                        row(theme, index: index)
                    }
                }
            }
        }
        .background(m3.surface)
        .overlay(alignment: .bottomTrailing) {
            if themes.count < CustomTheme.maxCount {
                ExtendedFAB(title: String(localized: "New theme"), icon: "add") { editing = EditorTarget(index: nil) }
                    .padding(16)
            }
        }
        .fullScreenCover(item: $editing) { target in
            CustomThemeEditor(index: target.index).environment(\.m3, m3)
        }
        .m3Dialog(
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            title: String(localized: "Delete \(deleting.flatMap { themes.indices.contains($0) ? themes[$0].name : nil } ?? "")?")
        ) {
            Text("This theme will be erased. If you're using it, the app switches to another theme.").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { deleting = nil }
            M3TextButton(title: String(localized: "Delete"), color: m3.error) {
                if let index = deleting { delete(index) }
                deleting = nil
            }
        }
    }

    private func info(count: Int) -> String {
        if count == 0 { return String(localized: "Make your own colour theme. You can keep up to \(CustomTheme.maxCount).") }
        if count >= CustomTheme.maxCount {
            return String(localized: "Tap a theme to use it. You have \(count) themes, the most you can keep; delete one to make another.")
        }
        return String(localized: "Tap a theme to use it. You can keep up to \(CustomTheme.maxCount).")
    }

    private func row(_ theme: CustomTheme, index: Int) -> some View {
        let preferences = app.preferences
        let selected = preferences.useCustomTheme && preferences.customThemeIndex == index
        return HStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach(CustomTheme.Role.allCases) { role in
                    Color(argb: theme[keyPath: role.keyPath]).frame(width: 12, height: 40)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(m3.outlineVariant))
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.system(size: 16)).foregroundStyle(m3.onSurface)
                if selected { Text("In use").font(M3Type.bodySmall).foregroundStyle(m3.primary) }
            }
            Spacer()
            AppBarIcon("edit", label: String(localized: "Edit \(theme.name)")) { editing = EditorTarget(index: index) }
            AppBarIcon("delete", label: String(localized: "Delete \(theme.name)")) { deleting = index }
        }
        .foregroundStyle(m3.onSurfaceVariant)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(selected ? m3.secondaryContainer.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            preferences.customThemeIndex = index
            preferences.useCustomTheme = true
        }
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func delete(_ index: Int) {
        let preferences = app.preferences
        var themes = preferences.customThemes
        guard themes.indices.contains(index) else { return }
        themes.remove(at: index)
        preferences.customThemes = themes
        if themes.isEmpty {
            preferences.useCustomTheme = false
            preferences.customThemeIndex = 0
        } else if preferences.customThemeIndex >= index {
            preferences.customThemeIndex = max(0, preferences.customThemeIndex - 1)
        }
    }
}

/// Android's theme editor: name, start from a built-in theme, six colours, contrast, a warning
/// for colours hard to see, and a full-screen preview.
struct CustomThemeEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let index: Int?
    @State private var theme: CustomTheme?
    @State private var original: CustomTheme?
    @State private var picking: CustomTheme.Role?
    @State private var startingFrom = false
    @State private var previewing = false
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            if let theme {
                editor(theme)
            } else {
                LoadingScreen()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard theme == nil else { return }
        let themes = app.preferences.customThemes
        if let index, themes.indices.contains(index) {
            theme = themes[index]
        } else {
            theme = CustomTheme.from(
                app.preferences.appTheme, dark: m3.isDark, name: String(localized: "My theme \(themes.count + 1)")
            )
        }
        original = theme
    }

    private var binding: Binding<CustomTheme> {
        Binding(get: { theme ?? CustomTheme.from(.default, dark: false, name: "") }, set: { theme = $0 })
    }

    private func editor(_ current: CustomTheme) -> some View {
        // The editor shows itself in the theme being made.
        let scheme = current.scheme(pureBlack: false)
        return VStack(spacing: 0) {
            TopAppBar(
                title: index == nil ? String(localized: "New theme") : String(localized: "Edit theme"),
                onBack: { if theme != original { confirmingDiscard = true } else { dismiss() } }
            ) {
                M3TextButton(title: String(localized: "Preview")) { previewing = true }
                M3TextButton(title: String(localized: "Save")) { save() }
            }
            ScrollView {
                VStack(spacing: 0) {
                    M3TextField(label: String(localized: "Name"), text: binding.name).padding(16)
                    PreferenceRow(
                        title: String(localized: "Start from a built-in theme"),
                        subtitle: String(localized: "Copy another theme's colours, then change what you like"),
                        action: { startingFrom = true }
                    )
                    PreferenceHeader(title: String(localized: "Colours"))
                    ForEach(CustomTheme.Role.allCases) { role in
                        let color = current[keyPath: role.keyPath]
                        PreferenceRow(title: role.title, subtitle: role.summary, action: { picking = role }) {
                            HStack(spacing: 8) {
                                Text(ColorMath.hex(color)).font(M3Type.labelMedium.monospaced()).foregroundStyle(scheme.onSurfaceVariant)
                                Circle().fill(Color(argb: color)).frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(scheme.outline, lineWidth: 1))
                            }
                        }
                    }
                    if !current.hardToRead.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            MIcon("warning").foregroundStyle(scheme.error)
                            Text("Hard to see on the background: \(current.hardToRead.map(\.title).joined(separator: ", ")). Text needs a contrast of 4.5:1 or more, the other colours 3:1. Each colour's picker shows its contrast.")
                                .font(M3Type.bodySmall)
                                .foregroundStyle(scheme.onSurface)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.errorContainer.opacity(0.5)))
                        .padding(16)
                    }
                    PreferenceHeader(title: String(localized: "Contrast"))
                    Text("How strongly text on buttons, outlines and shaded areas stand out from what they sit on")
                        .font(M3Type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Slider(value: binding.contrast, in: 0...1).tint(scheme.primary).padding(.horizontal, 16)
                    InfoPreference(text: String(localized: "A custom theme looks the same in light and dark mode. It's light or dark by its background colour."))
                }
                .padding(.bottom, 24)
            }
        }
        .environment(\.m3, scheme)
        .background(scheme.surface.ignoresSafeArea())
        .preferredColorScheme(current.isDark ? .dark : .light)
        .sheet(item: $picking) { role in
            ColorPickerSheet(title: role.title, color: binding[dynamicMember: role.keyPath], background: role.against(current), needed: role.neededContrast)
                .environment(\.m3, scheme)
        }
        .m3Dialog(isPresented: $startingFrom, title: String(localized: "Start from a built-in theme")) {
            VStack(spacing: 0) {
                ForEach(AppTheme.allCases) { builtIn in
                    ForEach([false, true], id: \.self) { dark in
                        RadioRow(title: dark ? String(localized: "\(builtIn.title) (dark)") : builtIn.title, selected: false) {
                            let name = theme?.name ?? ""
                            let contrast = theme?.contrast ?? 0.5
                            theme = CustomTheme.from(builtIn, dark: dark, name: name)
                            theme?.contrast = contrast
                            startingFrom = false
                        }
                    }
                }
            }
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { startingFrom = false }
        }
        .m3Dialog(isPresented: $confirmingDiscard, title: String(localized: "Discard changes?")) {
            Text("Your changes to this theme haven't been saved.").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Keep editing")) { confirmingDiscard = false }
            M3TextButton(title: String(localized: "Discard")) {
                confirmingDiscard = false
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $previewing) {
            CustomThemePreview(theme: current) { previewing = false }
        }
    }

    private func save() {
        guard var theme else { return }
        if theme.name.isBlank { theme.name = String(localized: "My theme \(app.preferences.customThemes.count + 1)") }
        let preferences = app.preferences
        var themes = preferences.customThemes
        if let index, themes.indices.contains(index) {
            themes[index] = theme
            preferences.customThemes = themes
        } else if themes.count < CustomTheme.maxCount {
            themes.append(theme)
            preferences.customThemes = themes
            preferences.customThemeIndex = themes.count - 1
            preferences.useCustomTheme = true
        }
        dismiss()
    }
}

/// Android's colour picker: standard colours, a colour wheel with brightness and saturation, or
/// a hex code; with the colour's contrast against the theme's background.
struct ColorPickerSheet: View {
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var color: UInt32
    let background: UInt32
    let needed: Double?
    @State private var tab = 0
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var hexText = ""

    /// Material's standard palette: each hue at three strengths, and greys.
    private static let standard: [UInt32] = [
        0xFFF44336, 0xFFE91E63, 0xFF9C27B0, 0xFF673AB7, 0xFF3F51B5, 0xFF2196F3, 0xFF03A9F4, 0xFF00BCD4,
        0xFF009688, 0xFF4CAF50, 0xFF8BC34A, 0xFFCDDC39, 0xFFFFEB3B, 0xFFFFC107, 0xFFFF9800, 0xFFFF5722,
        0xFFB71C1C, 0xFF880E4F, 0xFF4A148C, 0xFF311B92, 0xFF1A237E, 0xFF0D47A1, 0xFF01579B, 0xFF006064,
        0xFF004D40, 0xFF1B5E20, 0xFF33691E, 0xFF827717, 0xFFF57F17, 0xFFFF6F00, 0xFFE65100, 0xFFBF360C,
        0xFFFFCDD2, 0xFFF8BBD0, 0xFFE1BEE7, 0xFFD1C4E9, 0xFFC5CAE9, 0xFFBBDEFB, 0xFFB3E5FC, 0xFFB2EBF2,
        0xFFB2DFDB, 0xFFC8E6C9, 0xFFDCEDC8, 0xFFF0F4C3, 0xFFFFF9C4, 0xFFFFECB3, 0xFFFFE0B2, 0xFFFFCCBC,
        0xFF000000, 0xFF121212, 0xFF212121, 0xFF424242, 0xFF757575, 0xFFBDBDBD, 0xFFEEEEEE, 0xFFFFFFFF,
    ]

    var body: some View {
        let ratio = ColorMath.contrastRatio(color, background)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Circle().fill(Color(argb: color)).frame(width: 48, height: 48).overlay(Circle().strokeBorder(m3.outline))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(M3Type.titleLarge).foregroundStyle(m3.onSurface)
                    Text(String(format: "%@ · %.1f:1", ColorMath.hex(color), ratio))
                        .font(M3Type.bodyMedium.monospacedDigit())
                        .foregroundStyle(needed.map { ratio < $0 } == true ? m3.error : m3.onSurfaceVariant)
                }
                Spacer()
                M3TextButton(title: String(localized: "Done")) { dismiss() }
            }
            .padding(16)
            M3Tabs(tabs: [0, 1, 2], selection: $tab) {
                [String(localized: "Standard"), String(localized: "Colour wheel"), String(localized: "Hex code")][$0]
            }
            ScrollView {
                switch tab {
                case 0:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                        ForEach(Self.standard, id: \.self) { swatch in
                            Circle()
                                .fill(Color(argb: swatch))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Circle().strokeBorder(swatch == color ? m3.primary : m3.outlineVariant, lineWidth: swatch == color ? 3 : 1))
                                .onTapGesture { color = swatch }
                                .accessibilityLabel(ColorMath.hex(swatch))
                        }
                    }
                    .padding(16)
                case 1:
                    VStack(spacing: 16) {
                        wheel.frame(width: 240, height: 240)
                        labeledSlider(String(localized: "Brightness"), value: $brightness)
                        labeledSlider(String(localized: "Saturation"), value: $saturation)
                    }
                    .padding(16)
                    .onChange(of: hue) { applyHSB() }
                    .onChange(of: saturation) { applyHSB() }
                    .onChange(of: brightness) { applyHSB() }
                default:
                    M3TextField(label: String(localized: "Hex code"), text: $hexText, supporting: "#RRGGBB")
                        .padding(16)
                        .onChange(of: hexText) { _, text in if let parsed = ColorMath.parseHex(text) { color = parsed } }
                }
            }
        }
        .background(m3.surfaceContainerLow)
        .presentationDetents([.medium, .large])
        .presentationBackground(m3.surfaceContainerLow)
        .onAppear {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(Color(argb: color)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            (hue, saturation, brightness) = (Double(h), Double(s), Double(b))
            hexText = ColorMath.hex(color)
        }
    }

    private var wheel: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(Circle().fill(Color(argb: color)))
                    .frame(width: 28, height: 28)
                    .offset(x: cos(hue * 2 * .pi) * saturation * radius, y: sin(hue * 2 * .pi) * saturation * radius)
                    .shadow(radius: 2)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - radius
                let dy = value.location.y - radius
                var angle = atan2(dy, dx) / (2 * .pi)
                if angle < 0 { angle += 1 }
                hue = angle
                saturation = min(sqrt(dx * dx + dy * dy) / radius, 1)
            })
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Colour wheel"))
        .accessibilityValue(ColorMath.hex(color))
    }

    private func labeledSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(M3Type.labelLarge).foregroundStyle(m3.onSurface)
            Slider(value: value, in: 0...1).tint(m3.primary)
        }
    }

    private func applyHSB() {
        color = Color(hue: hue, saturation: saturation, brightness: brightness).argb
        hexText = ColorMath.hex(color)
    }
}

/// Android's full-screen preview of a custom theme: the main menu and some settings in its colours.
struct CustomThemePreview: View {
    let theme: CustomTheme
    let close: () -> Void
    @State private var checked = true
    @State private var switched = true

    var body: some View {
        let scheme = theme.scheme(pureBlack: false)
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Preview: \(theme.name)"), onBack: close)
            ScrollView {
                VStack(spacing: 0) {
                    PreferenceHeader(title: String(localized: "Main menu"))
                    HStack(spacing: 4) {
                        ForEach([("1", 3), ("2", 0), ("3", 12)], id: \.0) { name, unread in
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 4).fill(scheme.surfaceContainerHighest).aspectRatio(2 / 3, contentMode: .fit)
                                BadgeGroup {
                                    TextBadge(text: "2", color: scheme.tertiary, textColor: scheme.onTertiary)
                                    if unread > 0 { TextBadge(text: String(unread)) }
                                }
                                .padding(4)
                                .accessibilityLabel(name)
                            }
                        }
                    }
                    .padding(8)
                    SwitchPreference(title: String(localized: "Downloaded only"), subtitle: String(localized: "Filters all entries in your library"), icon: "cloud_off", isOn: $switched)
                    CheckboxRow(title: String(localized: "A checkbox"), isOn: $checked)
                    PreferenceRow(title: String(localized: "Settings"), icon: "settings")
                    HStack {
                        FilledButton(title: String(localized: "Resume"), icon: "play_arrow.fill") {}
                        M3TextButton(title: String(localized: "Cancel")) {}
                    }
                    .padding(16)
                }
            }
            NavBar(tabs: HomeTab.allCases, position: .bottom, alignment: .center, current: .library, badge: { $0 == .updates ? "4" : nil }) { _ in }
        }
        .environment(\.m3, scheme)
        .background(scheme.surface.ignoresSafeArea())
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
