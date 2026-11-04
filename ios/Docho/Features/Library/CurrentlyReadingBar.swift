import GRDB
import SwiftUI

/// A series being read, for the bar at the top of the library.
struct ReadingItem: Identifiable, Equatable, Sendable {
    var series: SeriesRecord
    /// The chapter to resume.
    var chapter: ChapterRecord
    var readChapters: Int
    var totalChapters: Int

    var id: Int { series.id }
}

extension AppDatabase {
    static let currentlyReadingLimit = 3

    /// The library series read most recently and not finished, updated as they change.
    func currentlyReading() -> AsyncValueObservation<[ReadingItem]> {
        ValueObservation
            .tracking { db -> [ReadingItem] in
                let recent = try Row.fetchAll(db, sql: """
                    SELECT c.seriesId AS seriesId, c.id AS chapterId, MAX(h.lastRead) AS lastRead
                    FROM history h
                    JOIN chapter c ON c.id = h.chapterId
                    JOIN series s ON s.id = c.seriesId
                    WHERE s.inLibrary
                    GROUP BY c.seriesId
                    ORDER BY lastRead DESC
                    LIMIT 50
                    """)
                var reading: [ReadingItem] = []
                for row in recent {
                    let seriesId: Int = row["seriesId"]
                    guard let series = try SeriesRecord.fetchOne(db, key: seriesId) else { continue }
                    let chapters = try ChapterRecord
                        .filter(ChapterRecord.Columns.seriesId == seriesId)
                        .order(ChapterRecord.Columns.readingOrder)
                        .fetchAll(db)
                    guard let resume = Self.resumeChapter(chapters, lastReadId: row["chapterId"]) else { continue }
                    reading.append(ReadingItem(
                        series: series, chapter: resume, readChapters: chapters.filter(\.read).count, totalChapters: chapters.count
                    ))
                    if reading.count == Self.currentlyReadingLimit { break }
                }
                return reading
            }
            .values(in: writer)
    }

    /// The chapter to go on with: the last one read if it's not finished, else the next unread one
    /// after it in reading order, else the first unread one. Nil if all are read.
    nonisolated static func resumeChapter(_ inOrder: [ChapterRecord], lastReadId: Int) -> ChapterRecord? {
        if let last = inOrder.firstIndex(where: { $0.id == lastReadId }) {
            if !inOrder[last].read { return inOrder[last] }
            if let next = inOrder[(last + 1)...].first(where: { !$0.read }) { return next }
        }
        return inOrder.first { !$0.read }
    }
}

/// The series being read, at most three, each with a Resume button, as on Dōchō Server.
struct CurrentlyReadingBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openReader) private var openReader
    @Environment(\.navigate) private var navigate
    @State private var items: [ReadingItem] = []

    var body: some View {
        // Not a Group: an empty one has no view to run the task on, so it'd stay empty.
        VStack(spacing: 0) {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Currently reading").font(M3Type.labelMedium).foregroundStyle(m3.onSurfaceVariant).padding(.horizontal, 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(items) { card($0) }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .task {
            do {
                for try await items in app.database.currentlyReading() { self.items = items }
            } catch {}
        }
    }

    private func card(_ item: ReadingItem) -> some View {
        let source = app.source(for: item.series)
        return HStack(spacing: 10) {
            Button {
                navigate(.series(item.series.id))
            } label: {
                HStack(spacing: 10) {
                    CoverImage(request: source.coverRequest(item.series.manga)).frame(height: 88)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.series.name).font(M3Type.titleSmall).foregroundStyle(m3.onSurface).lineLimit(1)
                        Text(item.chapter.inProgress
                            ? String(localized: "\(item.chapter.name) · page \(item.chapter.lastPageRead + 1)")
                            : item.chapter.name)
                            .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(1)
                        ProgressView(value: Double(item.readChapters), total: Double(max(item.totalChapters, 1)))
                        Text("\(item.readChapters) of \(item.totalChapters) read").font(M3Type.labelSmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FilledButton(title: String(localized: "Resume")) {
                Task {
                    guard let chapters = try? await app.database.chapterList(seriesId: item.series.id) else { return }
                    openReader(series: item.series, chapters: chapters, start: item.chapter)
                }
            }
        }
        .padding(.trailing, 8)
        .frame(width: 310, height: 96)
        .background(m3.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
