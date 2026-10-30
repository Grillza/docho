import Foundation
import Synchronization

/// Fetches one page image to a file the caller then owns.
protocol PageFetcher: Sendable {
    func fetch(_ url: URL) async throws -> (file: URL, mimeType: String?)
}

enum PageFetchError: LocalizedError, Equatable {
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .http(let status): "HTTP \(status)"
        }
    }
}

/// Fetches through an ordinary session; used by the tests.
struct SessionPageFetcher: PageFetcher {
    let session: URLSession

    func fetch(_ url: URL) async throws -> (file: URL, mimeType: String?) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw PageFetchError.http(status: status) }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: file)
        return (file, response.mimeType)
    }
}

/// `BackgroundPageFetcher.shared`, created on first use so tests never make a background session.
struct BackgroundFetch: PageFetcher {
    func fetch(_ url: URL) async throws -> (file: URL, mimeType: String?) {
        try await BackgroundPageFetcher.shared.fetch(url)
    }
}

/// Fetches through a background `URLSession`, so pages keep downloading while the app is
/// suspended. iOS wakes the app when they're done (`handleEventsForBackgroundURLSession`).
/// `@unchecked`: `session` is set once in `init`; everything else is behind the mutex.
final class BackgroundPageFetcher: NSObject, PageFetcher, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "app.doki.downloads"
    static let shared = BackgroundPageFetcher()

    private struct State {
        var waiting: [Int: CheckedContinuation<(file: URL, mimeType: String?), any Error>] = [:]
        var finished: [Int: Result<(file: URL, mimeType: String?), any Error>] = [:]
        var eventsDone: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private var session: URLSession!

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = DownloadManager.concurrentPages
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Called when iOS wakes the app for this session's events.
    func setEventsCompletion(_ completion: @escaping @Sendable () -> Void) {
        state.withLock { $0.eventsDone = completion }
    }

    func fetch(_ url: URL) async throws -> (file: URL, mimeType: String?) {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.waiting[task.taskIdentifier] = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns, so it's moved right away.
        let result: Result<(file: URL, mimeType: String?), any Error>
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if (200..<300).contains(status) {
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: file)
                result = .success((file, downloadTask.response?.mimeType))
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(PageFetchError.http(status: status))
        }
        state.withLock { $0.finished[downloadTask.taskIdentifier] = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, finished) = state.withLock { state in
            (state.waiting.removeValue(forKey: task.taskIdentifier), state.finished.removeValue(forKey: task.taskIdentifier))
        }
        let result = error.map { .failure($0) } ?? finished ?? .failure(URLError(.unknown))
        if let continuation {
            continuation.resume(with: result)
        } else if case .success(let file) = result {
            // From before the app was relaunched; the chapter is fetched again from the queue.
            try? FileManager.default.removeItem(at: file.file)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = state.withLock { state in
            defer { state.eventsDone = nil }
            return state.eventsDone
        }
        DispatchQueue.main.async { done?() }
    }
}
