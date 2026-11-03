import Darwin
import XCTest
@testable import Docho

/// The JVM linked into the app (PLAN-2 G5): boots the extension host and asks it a few things,
/// measuring what milestone 16 asks for. Skipped in builds without the runtime.
final class EmbeddedExtensionTests: XCTestCase {
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func testTheEmbeddedHostStartsAndAnswers() async throws {
        guard let runtime = EmbeddedExtensionTransport.Runtime.bundled() else { throw XCTSkip("No JVM in this build") }
        let before = Self.footprintMB()
        let clock = ContinuousClock()
        let started = clock.now
        let transport = EmbeddedExtensionTransport.shared
        try await Task.detached { try transport.start(runtime) }.value
        let booted = clock.now
        let host = ExtensionHost(transport: transport)
        let hello = try await host.start()
        let answered = clock.now
        print("embedded: JVM \(hello.jvm), engines \(hello.engines ?? [:])")
        print("embedded: start \(booted - started), first answer \(answered - booted), footprint \(Int(before)) → \(Int(Self.footprintMB())) MB")
        XCTAssertTrue(hello.jvm.contains("OpenJ9") || hello.jvm.contains("J9"), hello.jvm)
        XCTAssertGreaterThanOrEqual(hello.protocolVersion, 1)

        // A few calls that need no network: nothing installed, no repos.
        let installed = try await host.installedExtensions()
        let sources = try await host.sources()
        print("embedded: \(installed.count) extensions, \(sources.count) sources; footprint \(Int(Self.footprintMB())) MB")
        do {
            _ = try await host.popular("1", page: 1)
            XCTFail("an unknown source should fail")
        } catch let error as ExtensionRPC.RPCError {
            XCTAssertEqual(error.code, "SOURCE_NOT_FOUND")
        }
    }
}
