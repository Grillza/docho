import XCTest
@testable import Docho

/// Mirrors Android's `SyncValuesTest`.
final class DochoSyncTests: XCTestCase {
    func testCanonicalTextSortsKeysAndDropsNulls() throws {
        let value = SyncJSON(any: try JSONSerialization.jsonObject(with: Data(#"{"b":1,"a":"x","c":null,"d":{"z":true,"y":[2,1]}}"#.utf8)))
        XCTAssertEqual(value.canonical, #"{"a":"x","b":1,"d":{"y":[2,1],"z":true}}"#)
        XCTAssertEqual(SyncValues.rename(name: "Vol. 3", number: 3, original: nil, at: 5, mangaURL: nil).canonical, #"{"at":5,"name":"Vol. 3","number":"3"}"#)
        XCTAssertEqual(SyncValues.number(119.1), "119.1")
    }

    func testAValueFromTheServerReadsTheSameAsOneBuiltHere() throws {
        let here = SyncValues.chapter(mangaURL: "/series/1", read: false, bookmark: true, page: 4)
        let server = SyncJSON(any: try JSONSerialization.jsonObject(with: Data(#"{"read":false,"page":4,"manga":"/series/1","bookmark":true}"#.utf8)))
        XCTAssertEqual(here.canonical, server.canonical)
    }

    func testChangesAreWhatDifferAndDeletions() {
        let chapter = SyncValues.chapter(mangaURL: "/s", read: true, bookmark: false, page: 0)
        let current: [String: (kind: String, value: SyncJSON)] = [
            SyncValues.id("chapter", "1|/c/1"): ("chapter", chapter),
            SyncValues.id("chapter", "1|/c/2"): ("chapter", chapter),
            SyncValues.id("chapter", "1|/c/3"): ("chapter", chapter),
        ]
        let synced = [SyncValues.id("chapter", "1|/c/1"): chapter.canonical, SyncValues.id("manga", "1|/s"): "{}", SyncValues.id("manga", "1|/w"): "{}"]
        let changes = SyncValues.changes(
            current: current, synced: synced, pending: [SyncValues.id("chapter", "1|/c/3"), SyncValues.id("manga", "1|/w")], now: 9
        )
        XCTAssertEqual(changes.map { "\($0.kind) \($0.key) \($0.isDeleted)" }.sorted(), ["chapter 1|/c/2 false", "manga 1|/s true"])
    }

    func testAFirstSyncKeepsReadingFromBothDevices() {
        let local = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: true, page: 7)
        let remote = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 3)
        XCTAssertEqual(SyncValues.mergeChapter(local: local, remote: remote), SyncValues.chapter(mangaURL: "/s", read: false, bookmark: true, page: 7))
        XCTAssertEqual(SyncValues.parseKey("123|/a|b")?.1, "/a|b")
        XCTAssertNil(SyncValues.parseKey("nope"))
    }

    func testProgressComingDownNeverTakesTheDeviceBack() {
        let local = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: true, page: 120)
        let remote = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 110)
        XCTAssertEqual(
            SyncValues.mergeChapter(local: local, remote: remote, remoteBookmark: true),
            SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 120)
        )
        let behind = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 4)
        XCTAssertEqual(SyncValues.mergeChapter(local: behind, remote: remote, remoteBookmark: true), remote)
    }

    func testTheLaterChangeWinsByWhenItWasReadEvenGoingBack() {
        let further = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 110, at: 200)
        let back = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 4, at: 300)
        XCTAssertEqual(SyncValues.mergeChapter(local: further, remote: back), back)
        XCTAssertTrue(SyncValues.isBehind(back, further))
        let stale = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 4, at: 100)
        XCTAssertEqual(SyncValues.mergeChapter(local: further, remote: stale), further)
        let read = SyncValues.chapter(mangaURL: "/s", read: true, bookmark: false, page: 0, at: 200)
        let unread = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 0, at: 300)
        XCTAssertEqual(SyncValues.mergeChapter(local: read, remote: unread), unread)
    }

    func testWithoutATimeOnOneSideTheStoredTimeDecidesElseTheFurthestPoint() {
        let untimed = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 110)
        let back = SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 4, at: 300)
        XCTAssertEqual(SyncValues.mergeChapter(local: untimed, remote: back, localStored: 250), back)
        XCTAssertEqual(
            SyncValues.mergeChapter(local: untimed, remote: back, localStored: 350),
            SyncValues.chapter(mangaURL: "/s", read: false, bookmark: false, page: 110, at: 300)
        )
        // The same text as Android's, so records compare alike
        XCTAssertEqual(back.canonical, "{\"at\":300,\"bookmark\":false,\"manga\":\"/s\",\"page\":4,\"read\":false}")
    }
}
