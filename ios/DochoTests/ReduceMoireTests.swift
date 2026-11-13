import CoreGraphics
import UIKit
import XCTest
@testable import Docho

final class ReduceMoireTests: XCTestCase {
    private let size = 300

    /// White page; the top half is a dot screentone (a black dot in every other pixel of every
    /// other row); a black line 3 pixels high runs across at row 220.
    private func page() -> CGImage {
        var gray = [UInt8](repeating: 255, count: size * size)
        for y in 0..<150 where y % 2 == 0 {
            for x in 0..<size where x % 2 == 0 { gray[y * size + x] = 0 }
        }
        for y in 219...221 {
            for x in 0..<size { gray[y * size + x] = 0 }
        }
        let provider = CGDataProvider(data: Data(gray) as CFData)!
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// The red channel (0...1) of every pixel, row by row.
    private func reds(_ image: CGImage) -> [Double] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
    }

    func testScreentoneTurnsGreyAndLinesStay() throws {
        let filter = try XCTUnwrap(ReduceMoireFilter.shared, "no Metal device or kernels")
        let output = try XCTUnwrap(filter.apply(to: page(), scale: 0.4))
        XCTAssertEqual(output.width, size)
        XCTAssertEqual(output.height, size)
        let red = reds(output)
        func at(_ x: Int, _ y: Int) -> Double { red[y * size + x] }

        // Screentone, away from the edges: an even grey (a quarter of the pixels are black, so
        // linear light 0.75, sRGB about 0.88), no longer black and white dots.
        let tone = (40..<110).flatMap { y in (40..<260).map { at($0, y) } }
        XCTAssertLessThan(tone.max()! - tone.min()!, 0.06)
        XCTAssertEqual(tone.reduce(0, +) / Double(tone.count), 0.88, accuracy: 0.05)

        // The line keeps its darkness, and plain paper stays white.
        XCTAssertLessThan(at(150, 220), 0.35)
        XCTAssertGreaterThan(at(150, 270), 0.97)
    }

    func testPagesShownAtNearlyFullSizeAreLeftAlone() {
        let image = UIImage(cgImage: page())
        let processor = ReduceMoireProcessor(boxWidth: 290, boxHeight: 1000)
        XCTAssertEqual(processor.scale(for: CGSize(width: 300, height: 300)), 290.0 / 300, accuracy: 0.001)
        XCTAssertTrue(processor.process(image) === image)
    }

    func testScaleFitsTheBoxAndFollowsZoom() {
        let processor = ReduceMoireProcessor(boxWidth: 1000, boxHeight: 1000, zoom: 1.5)
        // A tall page is fitted by height: 1000 / 2000, then zoomed.
        XCTAssertEqual(processor.scale(for: CGSize(width: 1000, height: 2000)), 0.75, accuracy: 0.001)
        let strip = ReduceMoireProcessor(boxWidth: 1000, boxHeight: .greatestFiniteMagnitude)
        XCTAssertEqual(strip.scale(for: CGSize(width: 2000, height: 30000)), 0.5, accuracy: 0.001)
    }

    func testZoomIsRoundedToQuarters() {
        XCTAssertEqual(PageCell.zoomBucket(1), 1)
        XCTAssertEqual(PageCell.zoomBucket(1.005), 1)
        XCTAssertEqual(PageCell.zoomBucket(1.4), 1.5)
        XCTAssertEqual(PageCell.zoomBucket(2.6), 2.5)
    }
}
