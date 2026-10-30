import SwiftUI

/// Material 3 colour roles, as Compose's `ColorScheme` names them. Docho's screens are drawn with
/// these so the iOS app looks like the Android one.
struct M3ColorScheme: Sendable, Equatable {
    var primary: Color
    var onPrimary: Color
    var primaryContainer: Color
    var onPrimaryContainer: Color
    var inversePrimary: Color
    var secondary: Color
    var onSecondary: Color
    var secondaryContainer: Color
    var onSecondaryContainer: Color
    var tertiary: Color
    var onTertiary: Color
    var tertiaryContainer: Color
    var onTertiaryContainer: Color
    var background: Color
    var onBackground: Color
    var surface: Color
    var onSurface: Color
    var surfaceVariant: Color
    var onSurfaceVariant: Color
    var surfaceTint: Color
    var inverseSurface: Color
    var inverseOnSurface: Color
    var error: Color
    var onError: Color
    var errorContainer: Color
    var onErrorContainer: Color
    var outline: Color
    var outlineVariant: Color
    var surfaceContainerLowest: Color
    var surfaceContainerLow: Color
    var surfaceContainer: Color
    var surfaceContainerHigh: Color
    var surfaceContainerHighest: Color
    var isDark = false

    // swiftlint:disable:next function_parameter_count
    init(
        primary: UInt32, onPrimary: UInt32, primaryContainer: UInt32, onPrimaryContainer: UInt32, inversePrimary: UInt32,
        secondary: UInt32, onSecondary: UInt32, secondaryContainer: UInt32, onSecondaryContainer: UInt32,
        tertiary: UInt32, onTertiary: UInt32, tertiaryContainer: UInt32, onTertiaryContainer: UInt32,
        background: UInt32, onBackground: UInt32, surface: UInt32, onSurface: UInt32, surfaceVariant: UInt32,
        onSurfaceVariant: UInt32, surfaceTint: UInt32, inverseSurface: UInt32, inverseOnSurface: UInt32,
        error: UInt32, onError: UInt32, errorContainer: UInt32, onErrorContainer: UInt32, outline: UInt32,
        outlineVariant: UInt32, surfaceContainerLowest: UInt32, surfaceContainerLow: UInt32, surfaceContainer: UInt32,
        surfaceContainerHigh: UInt32, surfaceContainerHighest: UInt32
    ) {
        self.primary = Color(hex: primary)
        self.onPrimary = Color(hex: onPrimary)
        self.primaryContainer = Color(hex: primaryContainer)
        self.onPrimaryContainer = Color(hex: onPrimaryContainer)
        self.inversePrimary = Color(hex: inversePrimary)
        self.secondary = Color(hex: secondary)
        self.onSecondary = Color(hex: onSecondary)
        self.secondaryContainer = Color(hex: secondaryContainer)
        self.onSecondaryContainer = Color(hex: onSecondaryContainer)
        self.tertiary = Color(hex: tertiary)
        self.onTertiary = Color(hex: onTertiary)
        self.tertiaryContainer = Color(hex: tertiaryContainer)
        self.onTertiaryContainer = Color(hex: onTertiaryContainer)
        self.background = Color(hex: background)
        self.onBackground = Color(hex: onBackground)
        self.surface = Color(hex: surface)
        self.onSurface = Color(hex: onSurface)
        self.surfaceVariant = Color(hex: surfaceVariant)
        self.onSurfaceVariant = Color(hex: onSurfaceVariant)
        self.surfaceTint = Color(hex: surfaceTint)
        self.inverseSurface = Color(hex: inverseSurface)
        self.inverseOnSurface = Color(hex: inverseOnSurface)
        self.error = Color(hex: error)
        self.onError = Color(hex: onError)
        self.errorContainer = Color(hex: errorContainer)
        self.onErrorContainer = Color(hex: onErrorContainer)
        self.outline = Color(hex: outline)
        self.outlineVariant = Color(hex: outlineVariant)
        self.surfaceContainerLowest = Color(hex: surfaceContainerLowest)
        self.surfaceContainerLow = Color(hex: surfaceContainerLow)
        self.surfaceContainer = Color(hex: surfaceContainer)
        self.surfaceContainerHigh = Color(hex: surfaceContainerHigh)
        self.surfaceContainerHighest = Color(hex: surfaceContainerHighest)
    }

    /// The scheme for a theme and appearance (Android's `BaseColorScheme.getColorScheme`). Pure
    /// black can't be used for the navigation bar, as content scrolls behind it.
    static func of(_ theme: AppTheme, dark: Bool, pureBlack: Bool) -> M3ColorScheme {
        guard dark else { return theme.light }
        var scheme = theme.dark
        scheme.isDark = true
        guard pureBlack else { return scheme }
        scheme.background = .black
        scheme.onBackground = .white
        scheme.surface = .black
        scheme.onSurface = .white
        let container = Color(hex: 0x0C0C0C)
        scheme.surfaceVariant = container
        scheme.surfaceContainerLowest = container
        scheme.surfaceContainerLow = container
        scheme.surfaceContainer = container
        scheme.surfaceContainerHigh = Color(hex: 0x131313)
        scheme.surfaceContainerHighest = Color(hex: 0x1B1B1B)
        return scheme
    }

    /// M3 "surface tint" elevation overlays, used by top app bars once content scrolls under them.
    func surface(elevation level: Int) -> Color {
        switch level {
        case 0: surface
        case 1: surfaceContainerLow
        case 2: surfaceContainer
        case 3: surfaceContainerHigh
        default: surfaceContainerHighest
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private struct ColorSchemeKey: EnvironmentKey {
    static let defaultValue = M3ColorScheme.defaultLight
}

extension EnvironmentValues {
    /// The Material colour scheme of the current theme.
    var m3: M3ColorScheme {
        get { self[ColorSchemeKey.self] }
        set { self[ColorSchemeKey.self] = newValue }
    }
}

/// Material 3's type scale (Roboto sizes, set in the system font).
enum M3Type {
    static let displaySmall = Font.system(size: 36)
    static let headlineLarge = Font.system(size: 32)
    static let headlineMedium = Font.system(size: 28)
    static let headlineSmall = Font.system(size: 24)
    static let titleLarge = Font.system(size: 22)
    static let titleMedium = Font.system(size: 16, weight: .medium)
    static let titleSmall = Font.system(size: 14, weight: .medium)
    static let bodyLarge = Font.system(size: 16)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.system(size: 12)
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
}

/// A Material Symbol from the asset catalog, tinted like text.
struct MIcon: View {
    let name: String
    var size: CGFloat = 24

    init(_ name: String, size: CGFloat = 24) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Applies the chosen theme to everything below: the Material colours, the light/dark
/// appearance, and the tint of system controls.
struct ThemeRoot<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder var content: Content

    var body: some View {
        let preferences = app.preferences
        let dark = switch preferences.themeMode {
        case .system: systemScheme == .dark
        case .light: false
        case .dark: true
        }
        let scheme = M3ColorScheme.of(preferences.appTheme, dark: dark, pureBlack: preferences.pureBlack)
        content
            .environment(\.m3, scheme)
            .tint(scheme.primary)
            .preferredColorScheme(preferences.themeMode == .system ? nil : (dark ? .dark : .light))
    }
}
