import XCTest
@testable import Doki

/// Port of `KavitaSyncRulesTest.kt`.
final class KavitaSyncRulesTests: XCTestCase {
    private func progress(page: Int) -> KavitaProgress {
        KavitaProgress(volumeId: 1, chapterId: 5, pageNum: page, seriesId: 1, libraryId: 1)
    }

    private func queued(page: Int, markedByUser: Bool = false) -> PendingProgress {
        PendingProgress(progress(page: page), markedByUser: markedByUser)
    }

    func testAPageReadOfflineIsSentWhenItIsFurtherThanTheServer() {
        XCTAssertTrue(KavitaSync.shouldSend(queued(page: 10), serverPagesRead: 4))
    }

    func testAPageReadOfflineNeverUndoesProgressMadeOnAnotherDevice() {
        // Phone reached page 10 on the plane; the iPad got to page 20, or finished the 20-page chapter.
        XCTAssertFalse(KavitaSync.shouldSend(queued(page: 10), serverPagesRead: 20))
        XCTAssertFalse(KavitaSync.shouldSend(queued(page: 10), serverPagesRead: 10))
        // Finishing it on the phone too doesn't need sending again.
        XCTAssertFalse(KavitaSync.shouldSend(queued(page: 20), serverPagesRead: 20))
    }

    func testMarkingAChapterUnreadByHandGoesThrough() {
        XCTAssertTrue(KavitaSync.shouldSend(queued(page: 0, markedByUser: true), serverPagesRead: 20))
    }

    func testReadingOnAfterMarkingUnreadKeepsTheMarksPriorityUntilDelivered() {
        let mark = queued(page: 0, markedByUser: true)
        let merged = KavitaSync.mergePending(mark, progress(page: 3), markedByUser: false)
        XCTAssertTrue(merged.markedByUser)
        XCTAssertTrue(KavitaSync.shouldSend(merged, serverPagesRead: 20))

        XCTAssertFalse(KavitaSync.mergePending(nil, progress(page: 3), markedByUser: false).markedByUser)
    }
}
