import XCTest
@testable import Docho

/// Mirrors Android's `RenameLikeTest`.
final class RenameLikeTests: XCTestCase {
    private func like(_ original: String?, _ renamed: String, _ title: String, volume: Bool, _ names: String...) -> [String?] {
        guard let style = RenameLike.learn(original: original, renamed: renamed, seriesTitle: title, volume: volume) else {
            XCTFail("No style in \(renamed)")
            return []
        }
        return names.map { name in
            RenameLike.apply(style, to: name, seriesTitle: title).map { "\($0.name)|\(formatNumber($0.number))" }
        }
    }

    func testVolumeKeepsItsNumberAndDropsTheChapterRange() {
        XCTAssertEqual(
            like("Chainsaw v10 ch 10-15", "Vol. 10 - Chainsaw", "Chainsaw Man", volume: true, "Chainsaw v11 ch 16-20", "Chainsaw v2 ch 3-5"),
            ["Vol. 11 - Chainsaw|11", "Vol. 2 - Chainsaw|2"]
        )
    }

    func testChapterKeepsItsNumber() {
        XCTAssertEqual(
            like("Chainsaw v10 ch 12", "Chapter 12", "Chainsaw Man", volume: false, "Chainsaw v10 ch 13", "Chainsaw v3 ch 14.5"),
            ["Chapter 13|13", "Chapter 14.5|14.5"]
        )
    }

    func testRangesPaddingAndTitlesAreKept() {
        XCTAssertEqual(
            like(
                "Chainsaw Man Ch. 5 - Gun Devil", "Ch. 005: Gun Devil", "Chainsaw Man", volume: false,
                "Chainsaw Man Ch. 6 - Hello", "Chainsaw Man Ch. 7", "Chainsaw Man ch 8-9 - Two"
            ),
            ["Ch. 006: Hello|6", "Ch. 007|7", "Ch. 008: Two|8"]
        )
        XCTAssertEqual(like("Series v1 c1-4", "Volume 1 (Chapters 1-4)", "Series", volume: true, "Series v2 c5-9"), ["Volume 2 (Chapters 5-9)|2"])
    }

    func testTheExamplesOwnNameWorksWhenItWasntRenamed() {
        XCTAssertEqual(
            like(nil, "Vol. 3 - Chainsaw", "Chainsaw Man", volume: true, "Chainsaw v04", "Chainsaw Man 5"),
            ["Vol. 4 - Chainsaw|4", "Vol. 5 - Chainsaw|5"]
        )
        XCTAssertEqual(like(nil, "Vol. 2 Ch. 010", "X", volume: false, "x v3 c11"), ["Vol. 3 Ch. 011|11"])
    }

    func testNumbersInTheSeriesTitleArentReadAsChapters() {
        XCTAssertEqual(
            like("Kaiju No. 8 Vol. 2", "Volume 2", "Kaiju No. 8", volume: true, "Kaiju No. 8 Vol. 3", "Kaiju No. 8 v4"),
            ["Volume 3|3", "Volume 4|4"]
        )
    }

    func testNamesThatDontSayTheNumberAreLeft() {
        XCTAssertEqual(like("S ch 12", "Chapter 12", "S", volume: false, "Extra", "Vol. 2"), [nil, nil])
        XCTAssertEqual(like("S v1 ch 1", "Vol. 1 Ch. 1", "S", volume: false, "S ch 4"), [nil])
        XCTAssertNil(RenameLike.learn(original: "Something", renamed: "Bonus", seriesTitle: "S", volume: false))
    }
}
