import Foundation
import Observation

/// Pages through the Kavita series matching `request`.
@MainActor
@Observable
final class KavitaBrowseModel {
    var request = KavitaBrowseRequest()

    private(set) var series: [KavitaSeries] = []
    private(set) var hasNextPage = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    /// The request the shown series belong to.
    private(set) var loadedRequest: KavitaBrowseRequest?
    var isLoading: Bool { loadingGeneration == generation }

    private let client: KavitaClient
    private var nextPage = 1
    /// Bumped on every reload, so results for an older request are dropped.
    private var generation = 0
    private var loadingGeneration: Int?

    init(client: KavitaClient) {
        self.client = client
    }

    /// Starts again from page 1 with the current request.
    func reload() async {
        generation += 1
        loadedRequest = request
        series = []
        nextPage = 1
        hasNextPage = false
        error = nil
        await loadNextPage()
    }

    func loadNextPage() async {
        let generation = generation
        guard loadingGeneration != generation else { return }
        loadingGeneration = generation
        defer {
            if loadingGeneration == generation { loadingGeneration = nil }
        }
        do {
            let page = try await client.seriesPage(filter: request.filter, page: nextPage)
            guard generation == self.generation else { return }
            let known = Set(series.map(\.id))
            series += page.series.filter { !known.contains($0.id) }
            hasNextPage = page.hasNextPage
            nextPage += 1
        } catch {
            guard generation == self.generation, !Self.isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Loads more when `item` is near the end of what's shown.
    func loadMoreIfNeeded(after item: KavitaSeries) async {
        guard hasNextPage, error == nil, let index = series.firstIndex(where: { $0.id == item.id }),
              index >= series.count - 6
        else { return }
        await loadNextPage()
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
