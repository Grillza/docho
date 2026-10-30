import SwiftUI

/// Mihon's manga grid and list items (`CommonMangaItem.kt`): compact (title over the cover),
/// comfortable (title below), cover only, and list.
struct MangaItem: View {
    @Environment(\.m3) private var m3
    let title: String
    let cover: URLRequest?
    var mode: AppPreferences.DisplayMode = .compactGrid
    var selected = false
    /// Browse dims series already in the library.
    var dimmed = false
    var startBadges: [ItemBadge] = []
    var endBadges: [ItemBadge] = []
    var onContinueReading: (() -> Void)?

    enum ItemBadge: Hashable {
        case downloaded(Int)
        case unread(Int)
        case inLibrary
        case text(String)
    }

    private var coverAlpha: Double { selected ? 0.76 : (dimmed ? 0.34 : 1) }

    var body: some View {
        switch mode {
        case .list: list
        case .comfortableGrid: comfortable
        case .compactGrid, .coverOnlyGrid: compact
        }
    }

    private var compact: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(request: cover)
                .opacity(coverAlpha)
                .overlay {
                    if mode == .compactGrid {
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, Color(hex: 0x000000, alpha: 0.67)], startPoint: .top, endPoint: .bottom)
                                .frame(height: geometry.size.height * 0.33)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4))
                        .allowsHitTesting(false)
                    }
                }
            if mode == .compactGrid {
                HStack(alignment: .bottom, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .lineLimit(2)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    continueButton(small: true).padding([.trailing, .bottom], 6)
                }
            } else {
                continueButton(small: false)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .overlay(alignment: .topLeading) { badges(startBadges).padding(4) }
        .overlay(alignment: .topTrailing) { badges(endBadges).padding(4) }
        .padding(4)
        .background(selected ? m3.secondary : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var comfortable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(request: cover).opacity(coverAlpha)
                continueButton(small: false).padding(6)
            }
            .overlay(alignment: .topLeading) { badges(startBadges).padding(4) }
            .overlay(alignment: .topTrailing) { badges(endBadges).padding(4) }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(selected ? m3.onSecondary : m3.onSurface)
                .lineLimit(2, reservesSpace: true)
                .padding(4)
        }
        .padding(4)
        .background(selected ? m3.secondary : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var list: some View {
        HStack(spacing: 0) {
            CoverImage(request: cover, ratio: 1).frame(width: 40, height: 40).opacity(coverAlpha)
            Text(title)
                .font(M3Type.bodyMedium)
                .foregroundStyle(m3.onSurface)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            badges(startBadges + endBadges)
            continueButton(small: true).padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(selected ? m3.secondaryContainer.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func badges(_ badges: [ItemBadge]) -> some View {
        if !badges.isEmpty {
            BadgeGroup {
                ForEach(badges, id: \.self) { badge in
                    switch badge {
                    case .downloaded(let count): TextBadge(text: String(count), color: m3.tertiary, textColor: m3.onTertiary)
                    case .unread(let count): TextBadge(text: String(count))
                    case .inLibrary: TextBadge(text: String(localized: "In library"))
                    case .text(let text): TextBadge(text: text, color: m3.surfaceContainerHighest, textColor: m3.onSurface)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func continueButton(small: Bool) -> some View {
        if let onContinueReading {
            Button(action: onContinueReading) {
                MIcon("play_arrow.fill", size: small ? 16 : 20)
                    .foregroundStyle(m3.onPrimaryContainer)
                    .frame(width: small ? 28 : 32, height: small ? 28 : 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(m3.primaryContainer.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Resume"))
        }
    }

    private var accessibilityText: String {
        var parts = [title]
        for badge in startBadges + endBadges {
            switch badge {
            case .unread(let count): parts.append(String(localized: "\(count) unread"))
            case .downloaded(let count): parts.append(String(localized: "\(count) downloaded"))
            case .inLibrary: parts.append(String(localized: "In library"))
            case .text(let text): parts.append(text)
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// A grid or list of manga items, laid out as Mihon's library and browse grids.
struct MangaGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var mode: AppPreferences.DisplayMode
    var columns: Int = 0
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        if mode == .list {
            LazyVStack(spacing: 0) {
                ForEach(items) { cell($0) }
            }
        } else {
            LazyVGrid(
                columns: columns > 0
                    ? Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: columns)
                    : [GridItem(.adaptive(minimum: 120), spacing: 4, alignment: .top)],
                spacing: 4
            ) {
                ForEach(items) { cell($0) }
            }
            .padding(8)
        }
    }
}
