import DochoJVM
import Foundation
import os

/// The extension host on the JVM linked into the app (PLAN-2 G5), through the C shim in
/// `Docho/Native/DochoJVM`. One per process: a JVM can only be created once. The runtime from
/// `scripts/build-runtime.sh` (`ios/Embedded/`) is bundled as `jre/` (java.home) and
/// `host/oneechan-host.jar`.
final class EmbeddedExtensionTransport: ExtensionTransport, @unchecked Sendable {
    /// The bundled runtime, or nil when this build has no JVM.
    struct Runtime {
        let javaHome: URL
        let hostJar: URL
        let optionsFile: URL

        static func bundled(in bundle: Bundle = .main) -> Runtime? {
            guard oc_jvm_available() != 0, let jre = bundle.url(forResource: "jre", withExtension: nil),
                  let host = bundle.url(forResource: "host", withExtension: nil) else { return nil }
            let runtime = Runtime(
                javaHome: jre, hostJar: host.appending(path: "oneechan-host.jar"), optionsFile: jre.appending(path: "lib/oneechan-jvm.options")
            )
            return FileManager.default.fileExists(atPath: runtime.hostJar.path) ? runtime : nil
        }
    }

    static let shared = EmbeddedExtensionTransport()

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "io.github.grillza.docho", category: "extensions")
    private let directories: (data: URL, cache: URL, tmp: URL)

    private struct State {
        var started = false
        var nextId: Int64 = 0
        var calls: [Int64: CheckedContinuation<Data, any Error>] = [:]
        /// The host's fetch ids by the ids in their metadata.
        var fetchIds: [String: Int64] = [:]
        var listeners: [UUID: AsyncStream<ExtensionHostEvent>.Continuation] = [:]
    }

    private init() {
        let fm = FileManager.default
        let support = URL.applicationSupportDirectory.appending(path: "Extensions")
        directories = (support.appending(path: "data"), URL.cachesDirectory.appending(path: "Extensions"), fm.temporaryDirectory.appending(path: "Extensions"))
        for directory in [directories.data, directories.cache, directories.tmp] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Extensions and their data aren't backed up: they come from the repos again.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var supportURL = support
        try? supportURL.setResourceValues(values)
    }

    // MARK: Start

    /// Starts the JVM and the host (blocking, a few seconds); later calls return at once.
    func start(_ runtime: Runtime, maxHeapMB: Int = 512) throws {
        if lock.withLock({ $0.started }) { return }
        var options = [
            "-Djava.class.path=\(runtime.hostJar.path)", "-Djava.home=\(runtime.javaHome.path)",
            "-Djava.io.tmpdir=\(directories.tmp.path)", "-Duser.home=\(directories.data.path)", "-Xmx\(maxHeapMB)m",
            "-Djava.awt.headless=true", "-Dfile.encoding=UTF-8",
        ]
        let text = (try? String(contentsOf: runtime.optionsFile, encoding: .utf8)) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let option = line.trimmingCharacters(in: .whitespaces)
            guard !option.isEmpty, !option.hasPrefix("#") else { continue }
            options.append(
                option.replacingOccurrences(of: "${cacheDir}", with: directories.cache.path)
                    .replacingOccurrences(of: "${dataDir}", with: directories.data.path)
                    .replacingOccurrences(of: "${tmpDir}", with: directories.tmp.path)
                    .replacingOccurrences(of: "${javaHome}", with: runtime.javaHome.path)
            )
        }
        let config = try JSONEncoder().encode([
            "dataDir": directories.data.path, "cacheDir": directories.cache.path, "tmpDir": directories.tmp.path,
        ])

        var callbacks = oc_jvm_callbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.complete = { context, id, bytes, length in
            EmbeddedExtensionTransport.from(context).completed(id, Data(bytes: bytes!, count: length))
        }
        callbacks.emit = { context, bytes, length in
            EmbeddedExtensionTransport.from(context).emitted(Data(bytes: bytes!, count: length))
        }
        callbacks.fetch = { context, id, meta, metaLength, body, bodyLength in
            let body = body.map { pointer in
                Data(bytesNoCopy: pointer, count: bodyLength, deallocator: .free)
            }
            EmbeddedExtensionTransport.from(context).fetching(id, meta: Data(bytes: meta!, count: metaLength), body: body)
        }
        callbacks.fetch_cancel = { context, id in
            EmbeddedExtensionTransport.from(context).cancelled(id)
        }

        var error = [CChar](repeating: 0, count: 1024)
        let started = options.withCStringArray { pointers in
            config.withUnsafeBytes { raw in
                oc_jvm_start(nil, pointers, Int32(options.count), "oneechan/host/embedded/EmbeddedBridge",
                             raw.bindMemory(to: UInt8.self).baseAddress, config.count, callbacks, &error, error.count)
            }
        }
        guard started == 0 else {
            let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw ExtensionRPC.RPCError(code: "INTERNAL", message: message.isEmpty ? "The extension runtime didn't start" : message)
        }
        lock.withLock { $0.started = true }
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> EmbeddedExtensionTransport {
        Unmanaged<EmbeddedExtensionTransport>.fromOpaque(context!).takeUnretainedValue()
    }

    // MARK: Callbacks (on the host's threads)

    private func completed(_ id: Int64, _ data: Data) {
        lock.withLock { $0.calls.removeValue(forKey: id) }?.resume(returning: data)
    }

    private func emitted(_ data: Data) {
        guard let event = try? JSONDecoder().decode(ExtensionRPC.Event.self, from: data) else { return }
        broadcast(.other(event))
    }

    private func fetching(_ id: Int64, meta: Data, body: Data?) {
        guard let fetch = try? JSONDecoder().decode(ExtensionRPC.NetFetch.self, from: meta) else {
            let answer = #"{"id":"\#(id)","error":{"code":"INTERNAL","message":"Unreadable request"}}"#
            _ = answer.withCString { oc_jvm_fetch_result(id, UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), strlen($0), nil, 0) }
            return
        }
        lock.withLock { $0.fetchIds[fetch.id] = id }
        broadcast(.fetch(fetch, body: body))
    }

    private func cancelled(_ id: Int64) {
        let key = lock.withLock { state in state.fetchIds.first { $0.value == id }?.key }
        if let key { broadcast(.fetchCancel(id: key)) }
    }

    private func broadcast(_ event: ExtensionHostEvent) {
        for listener in lock.withLock({ Array($0.listeners.values) }) { listener.yield(event) }
    }

    // MARK: ExtensionTransport

    func call(_ request: Data) async throws -> Data {
        guard lock.withLock({ $0.started }) else {
            throw ExtensionRPC.RPCError(code: "INTERNAL", message: "The extension runtime isn't running")
        }
        let id = lock.withLock { state -> Int64 in
            state.nextId += 1
            return state.nextId
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { $0.calls[id] = continuation }
            let queued = request.withUnsafeBytes { raw in oc_jvm_call(id, raw.bindMemory(to: UInt8.self).baseAddress, request.count) }
            if queued != 0 {
                lock.withLock { $0.calls.removeValue(forKey: id) }?.resume(throwing: ExtensionRPC.RPCError(code: "INTERNAL", message: "The extension runtime stopped"))
            }
        }
    }

    func events() -> AsyncStream<ExtensionHostEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ExtensionHostEvent.self)
        lock.withLock { $0.listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    func respond(_ result: ExtensionRPC.NetFetchResult, body: Data?) async {
        guard let id = lock.withLock({ $0.fetchIds.removeValue(forKey: result.id) }) else { return }
        var meta = result
        meta.bodyBase64 = nil
        guard let json = try? JSONEncoder().encode(meta) else { return }
        // The shim takes ownership of the body copy and frees it with free().
        var buffer: UnsafeMutablePointer<UInt8>?
        if let body {
            buffer = malloc(max(body.count, 1))?.assumingMemoryBound(to: UInt8.self)
            if let buffer { body.copyBytes(to: buffer, count: body.count) }
        }
        _ = json.withUnsafeBytes { raw in
            oc_jvm_fetch_result(id, raw.bindMemory(to: UInt8.self).baseAddress, json.count, buffer, body?.count ?? 0)
        }
    }

    func readFile(_ path: String) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        // Fetched images are handed over to the app; icons stay.
        if url.standardizedFileURL.path.hasPrefix(directories.cache.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return data
    }
}

private extension Array where Element == String {
    /// Runs `body` with the strings as a C array of C strings.
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let duplicated = map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        let pointers = duplicated.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
