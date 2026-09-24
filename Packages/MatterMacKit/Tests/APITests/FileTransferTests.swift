import Foundation
import Testing
import MatterMacModels
@testable import MattermostAPI
import TestSupport

@Suite("Explicit file transfers")
struct FileTransferTests {
    @Test func pastedImageExportPreservesOriginalOnFailureAndReplacesOnSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("image.png")
        let original = Data("existing fixture".utf8)
        try original.write(to: destination)
        let image = CoreFixtures.png()
        let source = try UploadSource(pastedImage: image, typeIdentifier: "public.png", maximumBytes: image.count, onRelease: {})
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await source.exportPastedImage(to: destination)
        }
        await #expect(throws: APIError.cancelled) { try await cancelled.value }
        #expect(try Data(contentsOf: destination) == original)
        // An existing directory cannot be replaced with a file. Partial output is removed.
        let protectedDirectory = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        await #expect(throws: APIError.localFileUnavailable) { try await source.exportPastedImage(to: protectedDirectory) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["image.png", "protected"])
        let file = UploadSource(fileURL: destination, fileName: "image.png", expectedSize: Int64(original.count))
        await #expect(throws: APIError.localFileUnavailable) { try await file.exportPastedImage(to: destination) }
        #expect(try Data(contentsOf: destination) == original)
        try await source.exportPastedImage(to: destination)
        #expect(try Data(contentsOf: destination) == image)
        #expect(source.memoryBytes == image.count) // Export never consumes the unsent source.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["image.png", "protected"])
    }

    @Test(arguments: [false, true])
    func pastedImageUsesRawMemoryBodyAndRefusesRedirects(redirect: Bool) async throws {
        let data = CoreFixtures.png()
        let source = try UploadSource(pastedImage: data, typeIdentifier: "public.png", maximumBytes: data.count, onRelease: {})
        let server = try await LocalHTTPServer.start { request in
            #expect(request.method == "POST")
            #expect(request.path == "/api/v4/files")
            #expect(request.body == data)
            #expect(request.headers["Authorization"] == "Bearer image-test")
            #expect(request.headers["Cookie"] == nil)
            #expect(request.headers["Content-Length"] == String(data.count))
            if redirect { return .redirect(307, to: "/should-not-follow") }
            return .json("{\"file_infos\":[{\"id\":\"abcdefghijklmnopqrstuvwx01\",\"name\":\"image.png\",\"size\":\(data.count),\"mime_type\":\"image/png\"}]}")
        }
        defer { server.stop() }
        let service = DefaultMattermostServiceFactory().service(for: server.endpoint(),
            credential: BearerCredential(token: "image-test", kind: .session)!)
        do {
            let file = try await service.upload(source, channel: CoreFixtures.channel(1).id, clientID: "fixture", progress: { _ in })
            #expect(!redirect)
            #expect(file.size == data.count)
        } catch {
            #expect(redirect)
        }
        #expect(server.requests.count == 1)
        await service.shutdown()
    }

    @Test func selectedFileChangedBeforeUploadIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("before".utf8).write(to: file)
        let source = try #require(await UploadSource.selected([file], budget: .standard).first)
        // Same length, different inode: size-only checking would miss this change.
        try Data("after!".utf8).write(to: file, options: .atomic)
        let server = try await LocalHTTPServer.start { _ in .json("{}") }
        defer { server.stop() }
        let service = DefaultMattermostServiceFactory().service(for: server.endpoint(),
            credential: BearerCredential(token: "file-test", kind: .session)!)
        await #expect(throws: APIError.localFileUnavailable) {
            try await service.upload(source, channel: CoreFixtures.channel(1).id, clientID: "fixture", progress: { _ in })
        }
        #expect(server.requests.isEmpty)
        await service.shutdown()
    }

    @Test(arguments: [false, true])
    func failedOrCancelledDownloadPreservesDestination(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.txt")
        let original = Data("keep existing contents".utf8)
        try original.write(to: destination)
        let server = try await LocalHTTPServer.start { request in
            #expect(request.headers["Authorization"] == "Bearer file-test")
            #expect(request.headers["Cookie"] == nil)
            return cancel
                ? .init(status: 200, body: .chunked([Data(repeating: 1, count: 1024), Data(repeating: 2, count: 1024)], pause: .seconds(1)))
                : .json("{}", status: 403)
        }
        defer { server.stop() }
        let service = DefaultMattermostServiceFactory().service(for: server.endpoint(),
            credential: BearerCredential(token: "file-test", kind: .session)!)
        let task = Task { try await service.download(FileID(unchecked: "filefixture"), to: destination, progress: { _ in }) }
        if cancel {
            let deadline = ContinuousClock.now + .seconds(3)
            var hasPartialBytes = false
            repeat {
                let outputs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                hasPartialBytes = outputs.contains { url in
                    url != destination && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
                }
                if !hasPartialBytes { try await Task.sleep(for: .milliseconds(5)) }
            } while !hasPartialBytes && ContinuousClock.now < deadline
            #expect(hasPartialBytes)
            task.cancel()
        }
        do { try await task.value; Issue.record("Failed download was reported as successful") } catch {}
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.txt"])
        await service.shutdown()
    }
}
