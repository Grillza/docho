import SwiftUI

/// One chapter's new name, number and kind (Android's `RenameChapters.Request`). `kind` is
/// `ChapterMemo.kindVolume` or `kindChapter`, or nil to leave it.
struct ChapterRenameRequest: Equatable {
    var chapter: ChapterRecord
    var name: String
    var number: Double
    var kind: String?

    var renames: Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && (name != chapter.name || number != chapter.number)
    }

    var changesKind: Bool { kind.map { ($0 == ChapterMemo.kindVolume) != chapter.isVolume } ?? false }

    var changes: Bool { renames || changesKind }
}

/// How far a rename reaches past Dōchō, shown under the fields.
enum RenameReach {
    case localFiles, server, appOnly

    static func of(source: Int64) -> RenameReach {
        switch source {
        case LocalSource.id: .localFiles
        case KavitaSource.id, KomgaSource.id, BookOrbitSource.id: .server
        default: .appOnly
        }
    }
}

/// What the rename dialog has typed in. One chapter gets a name and number; several get text
/// replaced in their names, e.g. taking "Kaiju No. 8 " off every name so the 8 isn't read as the
/// chapter number. Numbers left out are read from the new names, or else kept.
struct RenameDraft: Equatable {
    var name = ""
    var number = ""
    var find = ""
    var replace = ""
    var kind: String?

    init() {}

    init(chapters: [ChapterRecord]) {
        if chapters.count == 1, let chapter = chapters.first {
            name = chapter.name
            number = chapter.number >= 0 ? formatNumber(chapter.number) : ""
            kind = chapter.isVolume ? ChapterMemo.kindVolume : ChapterMemo.kindChapter
        }
    }

    private var typedNumber: Double? {
        Double(number.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    func numberValid(single: Bool) -> Bool {
        !single || number.isBlank || typedNumber != nil
    }

    func requests(for chapters: [ChapterRecord], seriesTitle: String) -> [ChapterRenameRequest] {
        func numberFor(_ chapter: ChapterRecord, _ newName: String, typed: Double?) -> Double {
            if let typed { return typed }
            let parsed = ChapterNumber.parse(seriesTitle: seriesTitle, chapterName: newName)
            return parsed >= 0 ? parsed : chapter.number
        }
        if chapters.count == 1, let chapter = chapters.first {
            let newName = name.trimmingCharacters(in: .whitespaces)
            return [ChapterRenameRequest(chapter: chapter, name: newName, number: numberFor(chapter, newName, typed: typedNumber), kind: kind)]
        }
        return chapters.map { chapter in
            let newName = find.isEmpty
                ? chapter.name : chapter.name.replacingOccurrences(of: find, with: replace).trimmingCharacters(in: .whitespaces)
            return ChapterRenameRequest(chapter: chapter, name: newName, number: numberFor(chapter, newName, typed: nil), kind: kind)
        }
    }

    func canConfirm(for chapters: [ChapterRecord], seriesTitle: String) -> Bool {
        let requests = requests(for: chapters, seriesTitle: seriesTitle)
        return numberValid(single: chapters.count == 1) && requests.allSatisfy { !$0.name.isEmpty } && requests.contains(where: \.changes)
    }
}

/// The rename dialog's fields (Android's `RenameChaptersDialog`).
struct RenameChaptersFields: View {
    @Environment(\.m3) private var m3
    @Binding var draft: RenameDraft
    let chapters: [ChapterRecord]
    let seriesTitle: String
    let sourceName: String
    let reach: RenameReach

    private static let previewCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chapters.count == 1 {
                M3TextField(label: String(localized: "Name"), text: $draft.name)
                M3TextField(
                    label: String(localized: "Chapter number"), text: $draft.number, keyboard: .decimalPad,
                    supporting: draft.numberValid(single: true)
                        ? String(localized: "Leave empty to read it from the name") : String(localized: "Not a number")
                )
            } else {
                M3TextField(label: String(localized: "Find"), text: $draft.find)
                M3TextField(label: String(localized: "Replace with"), text: $draft.replace)
                Text("Preview").font(M3Type.labelLarge).foregroundStyle(m3.onSurface)
                let requests = draft.requests(for: chapters, seriesTitle: seriesTitle)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(requests.prefix(Self.previewCount).enumerated()), id: \.offset) { _, request in
                        Text((request.number >= 0 ? "\(formatNumber(request.number)) · " : "") + request.name)
                            .font(M3Type.bodySmall)
                            .lineLimit(1)
                    }
                    if requests.count > Self.previewCount { Text("…").font(M3Type.bodySmall) }
                }
            }
            Text("Type").font(M3Type.labelLarge).foregroundStyle(m3.onSurface)
            HStack(spacing: 8) {
                if chapters.count > 1 { kindChip(nil, String(localized: "Keep")) }
                kindChip(ChapterMemo.kindVolume, String(localized: "Volume"))
                kindChip(ChapterMemo.kindChapter, String(localized: "Chapter"))
            }
            Text("Sort the series by volumes or chapters first in its sort settings.").font(M3Type.bodySmall)
            Text(note).font(M3Type.bodySmall)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: String {
        switch reach {
        case .localFiles: String(localized: "The files on this device are renamed too.")
        case .server: String(localized: "The new name is sent to \(sourceName) too.")
        case .appOnly: String(localized: "This source can't rename its chapters, so they're renamed in Dōchō only.")
        }
    }

    /// Material's filter chip.
    private func kindChip(_ value: String?, _ title: String) -> some View {
        let selected = draft.kind == value
        return Button { draft.kind = value } label: {
            HStack(spacing: 8) {
                if selected { MIcon("check", size: 18) }
                Text(title).font(M3Type.labelLarge)
            }
            .foregroundStyle(selected ? m3.onSecondaryContainer : m3.onSurfaceVariant)
            .padding(.horizontal, selected ? 8 : 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? m3.secondaryContainer : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.clear : m3.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
