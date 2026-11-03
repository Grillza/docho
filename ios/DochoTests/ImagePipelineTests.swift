import Nuke
import XCTest
@testable import Docho

/// The app's image pipeline (covers, pages, extension and source icons) loads ordinary images,
/// with the docho-ext:// handler installed beside the system's.
@MainActor
final class ImagePipelineTests: XCTestCase {
    func testLoadsAnImageFromAServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["DOCHO_IMAGE_TEST_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("No image URL")
        }
        AppModel.configureImagePipeline()
        let image = try await ImagePipeline.shared.image(for: ImageRequest(urlRequest: URLRequest(url: url)))
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
