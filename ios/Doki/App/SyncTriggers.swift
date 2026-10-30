import BackgroundTasks
import Network
import UIKit

/// When queued progress gets delivered (Android uses WorkManager for this):
/// - after a failure, retried in the app with exponential backoff (1 minute to 30 minutes);
/// - when the network comes back (`NWPathMonitor`);
/// - when the app becomes active, and when it goes to the background (with a little extra time);
/// - in a `BGAppRefreshTask`, which iOS runs opportunistically while the app is suspended.
@MainActor
final class SyncTriggers {
    static let refreshTaskIdentifier = "app.doki.progress-sync"
    private static let firstRetry: Duration = .seconds(60)
    private static let longestRetry: Duration = .seconds(30 * 60)

    private let sync: KavitaSync
    private let monitor = NWPathMonitor()
    private var networkUp = true
    private var retryTask: Task<Void, Never>?
    private var backoff = SyncTriggers.firstRetry
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(sync: KavitaSync) {
        self.sync = sync
    }

    func start() {
        Task { [weak self, requests = sync.retryRequests] in
            for await _ in requests {
                self?.scheduleRetry()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func sceneChanged(to phase: ScenePhaseChange) {
        switch phase {
        case .active:
            flush()
        case .background:
            sendBeforeSuspending()
        }
    }

    enum ScenePhaseChange {
        case active
        case background
    }

    /// The `BGAppRefreshTask` handler.
    func backgroundRefresh() async {
        await sync.sendWaitingPages()
        if await !sync.syncQueued() {
            submitBackgroundRefresh()
        }
    }

    private func networkChanged(isUp: Bool) {
        defer { networkUp = isUp }
        if isUp && !networkUp { flush() }
    }

    /// Delivers the queue now; a success also ends any waiting retry.
    private func flush() {
        Task {
            guard await sync.syncQueued() else { return }
            retryTask?.cancel()
            retryTask = nil
            backoff = Self.firstRetry
        }
    }

    private func scheduleRetry() {
        submitBackgroundRefresh()
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: backoff)
                guard !Task.isCancelled else { return }
                if await sync.syncQueued() {
                    backoff = Self.firstRetry
                    break
                }
                backoff = min(backoff * 2, Self.longestRetry)
            }
            self?.retryTask = nil
        }
    }

    /// Asks for a little time so pages still waiting out their pause, and the queue, get sent.
    private func sendBeforeSuspending() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Send reading progress") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task {
            await sync.sendWaitingPages()
            if await !sync.syncQueued() { submitBackgroundRefresh() }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func submitBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Fails in the simulator and when background refresh is off; the in-app retries remain.
        try? BGTaskScheduler.shared.submit(request)
    }

    deinit {
        monitor.cancel()
    }
}
