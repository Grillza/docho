import SwiftUI

/// A colour theme the user made (Android's `CustomTheme`, 0.25). Colours are ARGB, as on Android,
/// so themes could move between the apps. The rest of the scheme is worked out from these, more
/// or less strongly apart as `contrast` (0 to 1) says.
struct CustomTheme: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var primary: UInt32
    var secondary: UInt32
    var tertiary: UInt32
    var background: UInt32
    var surface: UInt32
    var text: UInt32
    var contrast: Double = 0.5

    /// How many custom themes can be kept.
    static let maxCount = 5

    /// The six colours the user picks, with Android's names and explanations.
    enum Role: CaseIterable, Identifiable {
        case primary, secondary, tertiary, background, surface, text

        var id: Self { self }

        var title: String {
            switch self {
            case .primary: String(localized: "Accent")
            case .secondary: String(localized: "Secondary")
            case .tertiary: String(localized: "Highlight")
            case .background: String(localized: "Background")
            case .surface: String(localized: "Bars and cards")
            case .text: String(localized: "Text")
            }
        }

        var summary: String {
            switch self {
            case .primary: String(localized: "Buttons, switches, tabs and selected items")
            case .secondary: String(localized: "Unread badges and the selected tab in the navigation bar")
            case .tertiary: String(localized: "Downloaded badges and other highlights")
            case .background: String(localized: "Behind every screen")
            case .surface: String(localized: "The navigation bar, menus and cards")
            case .text: String(localized: "Titles, labels and icons")
            }
        }

        var keyPath: WritableKeyPath<CustomTheme, UInt32> {
            switch self {
            case .primary: \.primary
            case .secondary: \.secondary
            case .tertiary: \.tertiary
            case .background: \.background
            case .surface: \.surface
            case .text: \.text
            }
        }

        /// The contrast a colour needs (WCAG): 4.5:1 for text, 3:1 for accent and secondary.
        /// Highlight only colours badges with their own text, so it isn't checked, as on Android.
        var neededContrast: Double? {
            switch self {
            case .text: 4.5
            case .primary, .secondary: 3
            default: nil
            }
        }

        /// What the picker measures the colour's contrast against (Android's `against`).
        func against(_ theme: CustomTheme) -> UInt32 {
            switch self {
            case .text, .primary, .secondary, .tertiary: theme.background
            case .background, .surface: theme.text
            }
        }
    }

    /// A custom theme with a built-in theme's colours, to start editing from.
    static func from(_ theme: AppTheme, dark: Bool, name: String) -> CustomTheme {
        let scheme = dark ? theme.dark : theme.light
        return CustomTheme(
            name: name, primary: scheme.primary.argb, secondary: scheme.secondary.argb, tertiary: scheme.tertiary.argb,
            background: scheme.background.argb, surface: scheme.surfaceContainer.argb, text: scheme.onBackground.argb
        )
    }

    /// Colours too hard to see (Android's ReadabilityWarning): text needs 4.5:1 against the
    /// background and the bars, accent and secondary 3:1 against the background.
    var hardToRead: [Role] {
        var unclear: [Role] = []
        if ColorMath.contrastRatio(text, background) < 4.5 || ColorMath.contrastRatio(text, surface) < 4.5 { unclear.append(.text) }
        for role in [Role.primary, .secondary] where ColorMath.contrastRatio(self[keyPath: role.keyPath], background) < 3 {
            unclear.append(role)
        }
        return unclear
    }

    /// Light or dark by its background, whatever the app's appearance setting.
    var isDark: Bool { ColorMath.isDark(background) }

    /// The full scheme (Android's `CustomColorScheme.build`): the picked colours as they are, the
    /// rest mixed from them. Pure black applies when the theme is dark.
    func scheme(pureBlack: Bool) -> M3ColorScheme {
        let contrast = min(max(self.contrast, 0), 1)
        let background = self.background
        let surface = self.surface
        let text = self.text
        let dark = isDark

        // Text on a colour: its best of black or white, tinted by the colour less as contrast rises.
        func on(_ color: UInt32) -> UInt32 { ColorMath.lerp(color, ColorMath.bestText(color), 0.8 + 0.2 * contrast) }
        // Containers sit between a colour and the background, nearer the colour as contrast rises.
        func container(_ color: UInt32) -> UInt32 { ColorMath.lerp(color, background, 0.6 - 0.3 * contrast) }
        // Surfaces a step further from the background than the bars, for raised things.
        func raised(_ step: Double) -> UInt32 { ColorMath.lerp(surface, text, step * (0.5 + contrast)) }

        let error: UInt32 = dark ? 0xFFFF_B4AB : 0xFFBA_1A1A
        let errorContainer = container(error)
        func rgb(_ argb: UInt32) -> UInt32 { argb & 0xFF_FFFF }

        var scheme = M3ColorScheme(
            primary: rgb(primary), onPrimary: rgb(on(primary)), primaryContainer: rgb(container(primary)),
            onPrimaryContainer: rgb(on(container(primary))), inversePrimary: rgb(ColorMath.lerp(primary, background, 0.5)),
            secondary: rgb(secondary), onSecondary: rgb(on(secondary)), secondaryContainer: rgb(container(secondary)),
            onSecondaryContainer: rgb(on(container(secondary))),
            tertiary: rgb(tertiary), onTertiary: rgb(on(tertiary)), tertiaryContainer: rgb(container(tertiary)),
            onTertiaryContainer: rgb(on(container(tertiary))),
            background: rgb(background), onBackground: rgb(text), surface: rgb(background), onSurface: rgb(text),
            surfaceVariant: rgb(surface), onSurfaceVariant: rgb(ColorMath.lerp(text, background, 0.3 - 0.25 * contrast)),
            surfaceTint: rgb(primary), inverseSurface: rgb(text), inverseOnSurface: rgb(background),
            error: rgb(error), onError: rgb(on(error)), errorContainer: rgb(errorContainer), onErrorContainer: rgb(on(errorContainer)),
            outline: rgb(ColorMath.lerp(text, background, 0.55 - 0.3 * contrast)),
            outlineVariant: rgb(ColorMath.lerp(text, background, 0.8 - 0.2 * contrast)),
            surfaceContainerLowest: rgb(ColorMath.lerp(background, surface, 0.25)),
            surfaceContainerLow: rgb(ColorMath.lerp(background, surface, 0.6)),
            surfaceContainer: rgb(surface), surfaceContainerHigh: rgb(raised(0.06)), surfaceContainerHighest: rgb(raised(0.12))
        )
        scheme.isDark = dark
        if dark, pureBlack {
            // As Android's BaseColorScheme with overrideDarkSurfaceContainers.
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
        }
        return scheme
    }
}

/// Colour arithmetic as Compose does it: WCAG luminance and contrast, and mixing in Oklab.
enum ColorMath {
    static func components(_ argb: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((argb >> 16) & 0xFF) / 255, Double((argb >> 8) & 0xFF) / 255, Double(argb & 0xFF) / 255)
    }

    static func argb(r: Double, g: Double, b: Double) -> UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// WCAG relative luminance (Compose's `Color.luminance()`).
    static func luminance(_ argb: UInt32) -> Double {
        let (r, g, b) = components(argb)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, from 1 (the same) to 21 (black on white).
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let (light, dark) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (light + 0.05) / (dark + 0.05)
    }

    static func isDark(_ argb: UInt32) -> Bool {
        contrastRatio(argb, 0xFFFF_FFFF) > contrastRatio(argb, 0xFF00_0000)
    }

    static func bestText(_ argb: UInt32) -> UInt32 { isDark(argb) ? 0xFFFF_FFFF : 0xFF00_0000 }

    /// Compose's `lerp(Color, Color, Float)`: interpolates in Oklab.
    static func lerp(_ start: UInt32, _ stop: UInt32, _ fraction: Double) -> UInt32 {
        let a = oklab(start)
        let b = oklab(stop)
        let t = min(max(fraction, 0), 1)
        return fromOklab(l: a.l + (b.l - a.l) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t)
    }

    private static func oklab(_ argb: UInt32) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = components(argb)
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func fromOklab(l: Double, a: Double, b: Double) -> UInt32 {
        let l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return argb(
            r: gamma(4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1),
            g: gamma(-1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1),
            b: gamma(-0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1)
        )
    }

    static func hex(_ argb: UInt32) -> String { String(format: "#%06X", argb & 0xFF_FFFF) }

    /// "#1A2B3C", "1a2b3c" or "#abc" as an opaque colour.
    static func parseHex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return 0xFF00_0000 | value
    }
}

extension Color {
    /// The colour as opaque ARGB (sRGB).
    var argb: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorMath.argb(r: Double(r), g: Double(g), b: Double(b))
    }

    init(argb: UInt32) {
        self.init(hex: argb & 0xFF_FFFF)
    }
}
