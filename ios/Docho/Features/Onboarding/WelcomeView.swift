import SwiftUI

/// The welcome guide shown on first launch (in the spirit of Mihon's onboarding): how to get
/// around, and how to add comics from files or a server. Settings → Advanced shows it again.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    /// Called when the guide closes; with true if the user chose to set up a server.
    let finish: (_ setUpServer: Bool) -> Void
    @State private var page = 0

    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < Self.pageCount - 1 {
                    M3TextButton(title: String(localized: "Skip")) { finish(false) }
                        .accessibilityIdentifier("welcome.skip")
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 8)
            TabView(selection: $page) {
                welcome.tag(0)
                navigation.tag(1)
                files.tag(2)
                servers.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(m3.surface.ignoresSafeArea())
        #if DEBUG
        // DOCHO_WELCOME=<page> opens the guide at that page, for screenshots.
        .onAppear { page = (ProcessInfo.processInfo.environment["DOCHO_WELCOME"].flatMap(Int.init) ?? 1) - 1 }
        #endif
    }

    // MARK: Pages

    private var welcome: some View {
        Page {
            Image("wordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 80)
                .foregroundStyle(m3.primary)
                .accessibilityLabel("Dōchō")
            Text("Welcome")
                .font(M3Type.headlineMedium)
                .foregroundStyle(m3.onSurface)
            Text("Read manga and comics from your own files, your own servers, and extensions, all in one library.")
                .font(M3Type.bodyLarge)
                .foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("Here's a quick look at how it works.")
                .font(M3Type.bodyMedium)
                .foregroundStyle(m3.onSurfaceVariant)
        }
    }

    private var navigation: some View {
        Page {
            Title(icon: "explore", text: String(localized: "Getting around"))
            VStack(alignment: .leading, spacing: 14) {
                Item(icon: "nav.library", title: String(localized: "Library"),
                     text: String(localized: "Series you've added. Tap one to see its chapters; hold to select several."))
                Item(icon: "nav.updates", title: String(localized: "Updates"),
                     text: String(localized: "New chapters in your library."))
                Item(icon: "nav.history", title: String(localized: "History"),
                     text: String(localized: "What you read last, to pick up where you left off."))
                Item(icon: "nav.browse", title: String(localized: "Browse"),
                     text: String(localized: "Your files, your servers and extensions: find series and add them to your library."))
                Item(icon: "nav.more", title: String(localized: "More"),
                     text: String(localized: "Downloads, categories, statistics and settings."))
            }
            Text(UIDevice.current.userInterfaceIdiom == .pad
                ? String(localized: "You can move the bar to any side, reorder its tabs or hide some in Settings → Appearance.")
                : String(localized: "You can reorder the bar's tabs or hide some in Settings → Appearance."))
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }

    private var files: some View {
        Page {
            Title(icon: "book", text: String(localized: "Add your own files"))
            VStack(alignment: .leading, spacing: 14) {
                Item(icon: "add", title: String(localized: "From the Files app"),
                     text: String(localized: "In Browse, open Local source and tap +. Pick comics from your device, iCloud Drive or any other place in Files."))
                Item(icon: "open_in_new", title: String(localized: "Open in Dōchō"),
                     text: String(localized: "Share or open a comic from another app, and it's added and opened."))
                Item(icon: "folder", title: String(localized: "Straight into the folder"),
                     text: String(localized: "Files › On My \(UIDevice.current.model) › Dōchō › local. Each folder is a series; each file or folder of images in it is a chapter."))
            }
            Text("CBZ, CBR, CB7, ZIP, RAR, 7Z, EPUB and PDF all work.")
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }

    private var servers: some View {
        Page {
            Title(icon: "dns", text: String(localized: "Connect a server"))
            VStack(alignment: .leading, spacing: 14) {
                Item(logos: ["brand.kavita", "brand.komga", "brand.bookorbit"], title: String(localized: "Your own library"),
                     text: String(localized: "Kavita, Komga and BookOrbit servers show up in Browse, and your reading progress syncs both ways."))
                Item(logos: ["brand.suwayomi"], title: String(localized: "Extensions"),
                     text: String(localized: "A Suwayomi server runs Mihon's extensions. Install them from Browse → Extensions."))
                Item(icon: "sync", title: String(localized: "Tracking and sync"),
                     text: String(localized: "Sign in to AniList, MyAnimeList, Kitsu or MangaUpdates, or KOReader sync, in Settings."))
            }
            Text("All of this is in Settings → Sync / Self-hosted sources. You can also do it later.")
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? m3.primary : m3.outlineVariant)
                        .frame(width: index == page ? 24 : 8, height: 8)
                }
            }
            .animation(.easeOut(duration: 0.2), value: page)
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Page \(page + 1) of \(Self.pageCount)"))
            if page == Self.pageCount - 1 {
                WideOutlinedButton(title: String(localized: "Set up a server")) { finish(true) }
                    .accessibilityIdentifier("welcome.server")
            }
            HStack(spacing: 12) {
                if page > 0 {
                    WideOutlinedButton(title: String(localized: "Back")) { withAnimation { page -= 1 } }
                }
                if page < Self.pageCount - 1 {
                    WideFilledButton(title: String(localized: "Next")) { withAnimation { page += 1 } }
                        .accessibilityIdentifier("welcome.next")
                } else {
                    WideFilledButton(title: String(localized: "Get started")) { finish(false) }
                        .accessibilityIdentifier("welcome.done")
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

// MARK: - Parts

/// One page: centred, scrolling if the screen is short, no wider than reads well.
private struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) { content }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

private struct Title: View {
    @Environment(\.m3) private var m3
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            MIcon(icon, size: 32)
                .foregroundStyle(m3.onPrimaryContainer)
                .frame(width: 64, height: 64)
                .background(Circle().fill(m3.primaryContainer))
                .accessibilityHidden(true)
            Text(text)
                .font(M3Type.headlineSmall)
                .foregroundStyle(m3.onSurface)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// An icon (or server logos) with a short title and explanation.
private struct Item: View {
    @Environment(\.m3) private var m3
    var icon: String?
    var logos: [String] = []
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let icon {
                    MIcon(icon).foregroundStyle(m3.primary)
                } else {
                    HStack(spacing: 3) {
                        ForEach(logos, id: \.self) { logo in
                            Image(logo).resizable().scaledToFit().frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .frame(width: 84, alignment: .center)
            .padding(.top, 2)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(M3Type.titleSmall).foregroundStyle(m3.onSurface)
                Text(text).font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WideFilledButton: View {
    @Environment(\.m3) private var m3
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(M3Type.labelLarge)
                .foregroundStyle(m3.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(m3.primary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct WideOutlinedButton: View {
    @Environment(\.m3) private var m3
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(M3Type.labelLarge)
                .foregroundStyle(m3.primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .overlay(Capsule().stroke(m3.outline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
