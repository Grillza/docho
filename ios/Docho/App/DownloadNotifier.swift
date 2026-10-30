import BackgroundTasks
import Foundation
import os
import UIKit
import UserNotifications

/// Part A of PLAN-2: what Android's download notification does, the iOS way.
/// - Local notifications for a finished queue ("Download completed", only while the app isn't
///   in front) and failed chapters ("Download failed: Series - Chapter"); tapping one opens the
///   series. Permission is asked the first time the user starts a download.
/// - On iOS/iPadOS 26+, downloads the user starts run as a `BGContinuedProcessingTask`, which
///   the system shows as a progress Live Activity on the Lock Screen and Home Screen. Cancelling
///   it (or its expiry) pauses the queue; the task ends when the queue empties or pauses.
@MainActor
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let taskPrefix = "io.github.grillza.docho.downloads."
    nonisolated private static let seriesKey = "seriesId"

    private weak var app: AppModel?
    private var activity: AnyObject?
    private var activityObserver: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "download-notifier")

    func attach(_ app: AppModel) {
        self.app = app
        UNUserNotificationCenter.current().delegate = self
        registerContinuedTask()
        Task { [weak self, events = app.downloads.events] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Called when the user starts downloads: asks for notification permission once, and
    /// starts the system progress activity.
    func userStartedDownloads(title: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startContinuedTask(subtitle: title)
    }

    // MARK: Notifications

    private func handle(_ event: DownloadEvent) async {
        guard let app else { return }
        switch event {
        case .queueFinished:
            finishContinuedTask(success: true)
            guard UIApplication.shared.applicationState != .active else { return }
            post(title: String(localized: "Download completed"), body: nil, seriesId: nil)
        case .failed(let seriesId, let chapterId, let message):
            let series = try? await app.database.seriesRecord(id: seriesId)
            let chapter = try? await app.database.chapter(id: chapterId)
            let name = [series?.name, chapter?.name].compactMap { $0 }.joined(separator: " - ")
            post(title: String(localized: "Download failed: \(name)"), body: message, seriesId: seriesId)
        case .finished:
            break
        }
    }

    private func post(title: String, body: String?, seriesId: Int?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        if let seriesId { content.userInfo = [Self.seriesKey: seriesId] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let seriesId = response.notification.request.content.userInfo[Self.seriesKey] as? Int
        await MainActor.run {
            if let seriesId { app?.pendingSeries = seriesId }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Failures show while the app is open too, as on Android; the bar covers the rest.
        [.banner, .list]
    }

    // MARK: Continued processing (iOS 26+)

    private func registerContinuedTask() {
        guard #available(iOS 26, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskPrefix + "*", using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { self?.run(task) }
        }
    }

    private func startContinuedTask(subtitle: String) {
        guard #available(iOS 26, *), activity == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskPrefix + UUID().uuidString, title: String(localized: "Downloading"), subtitle: subtitle
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("Continued processing unavailable: \(error)")
        }
    }

    @available(iOS 26, *)
    private func run(_ task: BGContinuedProcessingTask) {
        guard let app else { return task.setTaskCompleted(success: false) }
        activity = task
        task.progress.totalUnitCount = 1
        task.expirationHandler = { [weak self] in
            // Cancelled from the Live Activity, or out of time: pause, as Android's Pause.
            MainActor.assumeIsolated {
                app.preferences.downloadsPaused = true
                Task { await app.downloads.setPaused(true) }
                self?.finishContinuedTask(success: false)
            }
        }
        activityObserver = Task { [weak self] in
            do {
                for try await queue in app.database.downloadQueue() {
                    let total = queue.reduce(0) { $0 + max($1.download.pagesTotal, 1) }
                    let done = queue.reduce(0) { $0 + $1.download.pagesDone }
                    task.progress.totalUnitCount = Int64(max(total, 1))
                    task.progress.completedUnitCount = Int64(done)
                    if let current = queue.first {
                        task.updateTitle(String(localized: "Downloading"), subtitle: "\(current.seriesName) - \(current.chapterName)")
                    }
                    if queue.isEmpty || app.preferences.downloadsPaused {
                        self?.finishContinuedTask(success: queue.isEmpty)
                        return
                    }
                }
            } catch {}
        }
    }

    private func finishContinuedTask(success: Bool) {
        activityObserver?.cancel()
        activityObserver = nil
        if #available(iOS 26, *), let task = activity as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        activity = nil
    }
}

extension AppModel {
    /// Downloads the user asked for (not automatic ones): queued, with the system progress
    /// activity and notification permission (PLAN-2 Part A).
    func userDownload(_ chapters: [ChapterRecord]) async {
        let chapters = chapters.filter { !$0.isDownloaded }
        guard !chapters.isEmpty else { return }
        await downloads.download(chapters)
        let series = try? await database.seriesRecord(id: chapters[0].seriesId)
        notifier.userStartedDownloads(title: [series?.name, chapters.count == 1 ? chapters[0].name : nil].compactMap { $0 }.joined(separator: " - "))
    }
}
