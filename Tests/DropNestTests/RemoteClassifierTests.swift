import XCTest
import Foundation
import DropNestCore
@testable import DropNest

private final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RemoteClassifierTests: XCTestCase {
    func config() -> Configuration {
        var config = Configuration(); config.aiProvider = .compatible
        config.apiEndpoint = "http://127.0.0.1:11434/v1/chat/completions"; config.apiModel = "test-model"
        return config
    }
    func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: config)
    }
    func reply(_ content: String) throws -> (Int, Data) {
        (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]))
    }
    func testSplitFolderNameIsSentAsAHintOnlyWhenPresent() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var prompts: [String] = []
        MockProtocol.handler = { request in
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var chunk = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&chunk, maxLength: chunk.count); if count <= 0 { break }; body.append(chunk, count: count) }
            }
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let messages = payload["messages"] as! [[String: Any]]
            prompts.append(messages.last!["content"] as! String)
            return try self.reply(#"{"folder_id":0,"confident":true,"reason":"主题一致"}"#)
        }
        let library = LibrarySnapshot(folders: ["客户"])
        _ = try await RemoteClassifier.route(filename: "协议.docx", excerpt: "合作协议", config: config(), library: library,
                                             sourceFolder: "星河科技/合同", transport: session)
        _ = try await RemoteClassifier.route(filename: "协议.docx", excerpt: "合作协议", config: config(), library: library, transport: session)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].hasPrefix("来源文件夹（拖入时所在位置，仅作辅助线索，以内容为主）：星河科技/合同\n文件名：协议.docx"), prompts[0])
        XCTAssertTrue(prompts[1].hasPrefix("文件名：协议.docx"), prompts[1])
    }
    func testExistingMatchingFolderDoesNotRequestNewCategory() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            return try self.reply(#"{"folder_id":0,"confident":true,"reason":"主题一致"}"#)
        }
        let result = try await RemoteClassifier.route(filename: "学习笔记.txt", excerpt: "曝光与光圈", config: config(),
            library: LibrarySnapshot(folders: ["摄影学习"]), transport: session)
        XCTAssertEqual(result.folder, "摄影学习"); XCTAssertTrue(result.requiresExistingFolder)
        XCTAssertEqual(calls, 1)
    }
    func testUnmatchedFileCreatesFolderThenIsSearchableAndUndoable() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            return try self.reply(calls == 1 ? #"{"folder_id":-1,"confident":false,"reason":"无匹配"}"# : #"{"folder":"摄影学习","confident":true,"reason":"曝光与光圈学习笔记"}"#)
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-NewFolder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("代码"), withIntermediateDirectories: true)
        let source = base.appendingPathComponent("笔记.txt")
        try "光圈与曝光补偿练习".write(to: source, atomically: true, encoding: .utf8)
        var library = try LibraryScanner.scan(root: archive)
        let decision = try await RemoteClassifier.route(source, config: config(), library: library, transport: session)
        XCTAssertEqual(decision.folder, "摄影学习"); XCTAssertFalse(decision.requiresExistingFolder)
        XCTAssertEqual(calls, 2)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archive(source: source, root: archive, decision: decision)
        library.registerFolder(decision.folder)
        XCTAssertTrue(library.children(of: "").contains("摄影学习"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.destination))
        let worker = LibraryWorker(storage: base.appendingPathComponent("index.json"))
        let indexed = try await worker.rebuild(root: archive) { _, _ in }
        XCTAssertEqual(LibrarySearch.search(indexed, query: "曝光补偿").first?.document.path, "摄影学习/笔记.txt")
        MockProtocol.handler = { _ in
            calls += 1
            return try self.reply(#"{"folder_id":1,"confident":true,"reason":"复用摄影学习目录"}"#)
        }
        let next = try await RemoteClassifier.route(filename: "相机笔记.txt", excerpt: "光圈练习", config: config(), library: library, transport: session)
        XCTAssertEqual(next.folder, "摄影学习"); XCTAssertTrue(next.requiresExistingFolder)
        XCTAssertEqual(calls, 3)
        try journal.undo(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.destination))
    }
    func testCreatesNewChildUnderMatchingParent() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            switch calls {
            case 1: return try self.reply(#"{"folder_id":0,"confident":true,"reason":"客户文件"}"#)
            case 2: return try self.reply(#"{"folder_id":1,"confident":true,"reason":"属于另一客户"}"#)
            default: return try self.reply(#"{"folder":"山海服装","confident":true,"reason":"新客户山海服装"}"#)
            }
        }
        let result = try await RemoteClassifier.route(filename: "山海服装合同.txt", excerpt: "山海服装采购合同", config: config(),
            library: LibrarySnapshot(folders: ["客户", "客户/星河科技"]), transport: session)
        XCTAssertEqual(result.folder, "客户/山海服装"); XCTAssertFalse(result.requiresExistingFolder)
        XCTAssertEqual(calls, 3)
    }
    func testUncertainFileDoesNotCreateAnArbitraryCategory() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        MockProtocol.handler = { _ in try self.reply(#"{"folder":"","confident":false,"reason":"无语义线索"}"#) }
        let result = try await RemoteClassifier.route(filename: "random.bin", excerpt: "", config: config(), library: LibrarySnapshot(), transport: session)
        XCTAssertEqual(result.folder, "待整理")
    }
    func testInvalidNewFolderIsRetriedWithoutMovingAnything() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var calls = 0
        MockProtocol.handler = { _ in
            calls += 1
            return try self.reply(calls == 1 ? #"{"folder":"../escape","confident":true,"reason":"无效"}"# : #"{"folder":"摄影","confident":true,"reason":"摄影笔记"}"#)
        }
        let result = try await RemoteClassifier.route(filename: "note.txt", excerpt: "摄影练习", config: config(), library: LibrarySnapshot(), transport: session)
        XCTAssertEqual(result.folder, "摄影"); XCTAssertEqual(calls, 2)
    }
    func testSyntheticConnectionRequestAndValidatedResponse() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        MockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096); var body = Data()
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
                data = body
            } else { throw ArchiveError.invalid("Missing body") }
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(payload["model"] as? String, "test-model")
            let messages = payload["messages"] as! [[String: String]]
            XCTAssertTrue(messages[1]["content"]!.contains("synthetic test data"))
            let response = ["choices": [["message": ["content": #"{"category":"receipts","confident":true}"#]]]]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let decision = try await RemoteClassifier.classify(nil, config: config(), transport: session)
        XCTAssertEqual(decision.folder, "工作/票据")
    }
    func testRemoteConsentRequiredBeforeNetworkOrCredentials() async {
        var configuration = config(); configuration.apiEndpoint = "https://api.example.com/v1/chat/completions"
        let session = transport(); defer { session.invalidateAndCancel() }
        MockProtocol.handler = { _ in XCTFail("Must not send without consent"); return (500, Data()) }
        do { _ = try await RemoteClassifier.classify(nil, config: configuration, transport: session); XCTFail("Expected consent error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未允许")) }
    }
    func testServerErrorDoesNotExposeResponseBody() async {
        let session = transport(); defer { session.invalidateAndCancel() }
        MockProtocol.handler = { _ in (401, Data("private-response-secret".utf8)) }
        do { _ = try await RemoteClassifier.classify(nil, config: config(), transport: session); XCTFail("Expected server error") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("private-response-secret"))
        }
    }

    func testQwenUsesStrictSchemaWithoutThinkingOrCredentials() async throws {
        let session = transport(); defer { session.invalidateAndCancel() }
        var configuration = config(); configuration.apiModel = "qwen3.5:9b"
        MockProtocol.handler = { request in
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096); var body = Data()
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
                data = body
            } else { throw ArchiveError.invalid("Missing body") }
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(payload["reasoning_effort"] as? String, "none")
            XCTAssertEqual(payload["max_tokens"] as? Int, 512)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let format = payload["response_format"] as! [String: Any]
            XCTAssertEqual(format["type"] as? String, "json_schema")
            let schema = (format["json_schema"] as! [String: Any])["schema"] as! [String: Any]
            XCTAssertEqual(schema["required"] as? [String], ["category", "confident"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let response = ["choices": [["message": ["content": #"{"category":"receipts","confident":true}"#]]]]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let decision = try await RemoteClassifier.classify(nil, config: configuration, transport: session)
        XCTAssertEqual(decision.folder, "工作/票据")
    }
}

final class QwenLiveTests: XCTestCase {
    func testLocalQwenCreatesNewContentFolderAndReusesIt() async throws {
        guard ProcessInfo.processInfo.environment["DROPNEST_LIVE_QWEN"] == "1" else { throw XCTSkip("Local Qwen opt-in required") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Qwen-New-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("代码"), withIntermediateDirectories: true)
        let source = base.appendingPathComponent("笔记001.txt")
        try "摄影学习笔记：光圈、快门和ISO共同决定曝光。学习景深控制、构图方法及人像布光。这是虚构的测试文件。".write(to: source, atomically: true, encoding: .utf8)
        let library = try LibraryScanner.scan(root: root)
        let decision = try await RemoteClassifier.route(source, config: Configuration(), library: library)
        XCTAssertNotEqual(decision.folder, "待整理"); XCTAssertNotEqual(decision.folder, "代码")
        XCTAssertTrue(decision.folder.contains("摄影"), decision.folder)
        XCTAssertFalse(decision.requiresExistingFolder)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archive(source: source, root: root, decision: decision)
        let worker = LibraryWorker(storage: base.appendingPathComponent("index.json"))
        let indexed = try await worker.rebuild(root: root) { _, _ in }
        XCTAssertEqual(LibrarySearch.search(indexed, query: "景深控制").first?.document.path, decision.folder + "/笔记001.txt")
        let second = try await RemoteClassifier.route(filename: "笔记002.txt", excerpt: "摄影学习：练习光圈与快门，掌握景深、构图与人像布光。", config: Configuration(), library: indexed)
        XCTAssertEqual(second.folder, decision.folder); XCTAssertTrue(second.requiresExistingFolder)
        print("Synthetic Qwen new folder: \(decision.folder); subsequent file reused it; content search passed")
        try journal.undo(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    /// Explicit opt-in: only synthetic fixtures are sent to the local model.
    func testLocalQwenClassifiesSyntheticFiles() async throws {
        guard ProcessInfo.processInfo.environment["DROPNEST_LIVE_QWEN"] == "1" else {
            throw XCTSkip("Set DROPNEST_LIVE_QWEN=1 to test the running local Qwen model.")
        }
        var configuration = Configuration()
        configuration.aiProvider = .compatible
        configuration.apiEndpoint = "http://127.0.0.1:11434/v1/chat/completions"
        configuration.apiModel = "qwen3.5:9b"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Qwen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = [
            ("办公用品发票.txt", "增值税普通发票。购买方：测试公司。办公用品采购，金额120元。本文件为虚构测试样例。", "工作/票据"),
            ("服务合同.txt", "技术服务合同。甲方：测试甲公司。乙方：测试乙公司。双方约定服务期限一年，费用一万元，违约方承担违约责任。本文件为虚构测试样例。", "工作/合同"),
            ("个人简历.txt", "个人简历。姓名：测试姓名。求职意向：软件工程师。教育经历：计算机本科。工作经历：三年软件开发。本文件为虚构测试样例。", "工作/简历")
        ]
        for (name, content, expected) in fixtures {
            let file = directory.appendingPathComponent(name)
            try content.write(to: file, atomically: true, encoding: .utf8)
            let result = try await RemoteClassifier.classify(file, config: configuration)
            XCTAssertEqual(result.folder, expected, name)
        }
    }
    func testLocalQwenRoutesIntoCustomExistingTree() async throws {
        guard ProcessInfo.processInfo.environment["DROPNEST_LIVE_QWEN"] == "1" else { throw XCTSkip("Local Qwen opt-in required") }
        let configuration = Configuration()
        let library = LibrarySnapshot(rootPath: "/synthetic", folders: [
            "客户", "客户/星河科技", "客户/星河科技/项目文书", "客户/山海服装", "客户/山海服装/费用凭证",
            "个人", "个人/日本行程", "研发", "研发/桌面工具", "待整理"
        ], documents: [
            LibraryDocument(path: "客户/星河科技/项目文书/协议.txt", size: 1, modified: Date(), text: "星河科技技术服务合同"),
            LibraryDocument(path: "个人/日本行程/机票.txt", size: 1, modified: Date(), text: "日本东京旅游预订")
        ])
        let contract = try await RemoteClassifier.route(filename: "星河科技服务协议.txt",
            excerpt: "甲方星河科技与乙方签订软件开发服务协议，服务期限一年，约定开发费用和违约责任。", config: configuration, library: library)
        XCTAssertEqual(contract.folder, "客户/星河科技/项目文书")
        XCTAssertTrue(contract.requiresExistingFolder)
        let travel = try await RemoteClassifier.route(filename: "酒店订单.txt", excerpt: "个人日本东京旅游，酒店预订确认，入住日期和旅行行程。", config: configuration, library: library)
        XCTAssertEqual(travel.folder, "个人/日本行程")
        let unknown = try await RemoteClassifier.route(filename: "random.bin", excerpt: "qzxv 4389", config: configuration, library: library)
        XCTAssertEqual(unknown.folder, "待整理")
    }
}
