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

    /// The notifier the registered task handler forwards to; set by `attach`.
    private static weak var current: DownloadNotifier?
    /// Whether the continued-processing handler was registered at launch. Submitting without it
    /// raises an Objective-C exception, so nothing is submitted then.
    private static var registered = false

    private weak var app: AppModel?
    private var activity: AnyObject?
    /// A task submitted that the system hasn't started yet, so a second tap doesn't submit another.
    private var submitted = false
    private var activityObserver: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "download-notifier")

    func attach(_ app: AppModel) {
        self.app = app
        UNUserNotificationCenter.current().delegate = self
        Self.current = self
        Task { [weak self, events = app.downloads.events] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Called when the user starts downloads: starts the system progress activity, then asks for
    /// notification permission once. The task goes first: it has to be submitted while the app is
    /// in front, which it no longer is while the permission alert is up.
    func userStartedDownloads(title: String) {
        startContinuedTask(subtitle: title)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    /// Registers the handler for downloads' continued-processing tasks. Called while the app
    /// finishes launching, as BackgroundTasks requires.
    static func registerContinuedTask() {
        guard #available(iOS 26, *) else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskPrefix + "*", using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let notifier = current else {
                    return task.setTaskCompleted(success: false)
                }
                notifier.run(task)
            }
        }
    }

    private func startContinuedTask(subtitle: String) {
        guard #available(iOS 26, *), Self.registered, activity == nil, !submitted else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskPrefix + UUID().uuidString, title: String(localized: "Downloading"), subtitle: subtitle
        )
        // Run now or not at all. A queued request (the default) can wait behind other apps' tasks
        // and only show its progress once the downloads are well under way; the download bar
        // covers the app either way.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = true
        } catch {
            log.info("Continued processing unavailable: \(error)")
        }
    }

    @available(iOS 26, *)
    private func run(_ task: BGContinuedProcessingTask) {
        submitted = false
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
            // The task can start before the chapters are queued; an empty queue only ends it once
            // there has been something in it.
            var started = false
            do {
                for try await queue in app.database.downloadQueue() {
                    started = started || !queue.isEmpty
                    let total = queue.reduce(0) { $0 + max($1.download.pagesTotal, 1) }
                    let done = queue.reduce(0) { $0 + $1.download.pagesDone }
                    task.progress.totalUnitCount = Int64(max(total, 1))
                    task.progress.completedUnitCount = Int64(done)
                    if let current = queue.first {
                        task.updateTitle(String(localized: "Downloading"), subtitle: "\(current.seriesName) - \(current.chapterName)")
                    }
                    if (started && queue.isEmpty) || app.preferences.downloadsPaused {
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
        // The activity starts before the chapters are queued, so it shows as soon as they're tapped.
        let series = try? await database.seriesRecord(id: chapters[0].seriesId)
        notifier.userStartedDownloads(title: [series?.name, chapters.count == 1 ? chapters[0].name : nil].compactMap { $0 }.joined(separator: " - "))
        await downloads.download(chapters)
    }
}
