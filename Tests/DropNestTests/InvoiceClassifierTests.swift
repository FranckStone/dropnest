import XCTest
import Foundation
import DropNestCore
@testable import DropNest

private final class InvoiceProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class InvoiceLiveTests: XCTestCase {
    func testLocalQwenClassifiesSyntheticInvoicesByPurposeType() async throws {
        guard ProcessInfo.processInfo.environment["DROPNEST_LIVE_QWEN"] == "1" else { throw XCTSkip("Local Qwen opt-in required") }
        let context = try InvoiceContext(sourceFolder: URL(fileURLWithPath: "/synthetic/10月差旅"), relativeFolder: "上海出差",
            purpose: "出差报销", categories: ["交通", "住宿", "餐饮", "办公用品"])
        for (content, expected) in [
            ("增值税电子普通发票。购买方：虚构测试公司。项目名称：住宿服务，上海出差酒店住宿费，金额500元。本文件为虚构测试样例。", "住宿"),
            ("电子普通发票。购买方：虚构测试公司。项目名称：客运服务，上海市出租汽车车费，金额60元。本文件为虚构测试样例。", "交通")
        ] {
            let result = try await RemoteClassifier.invoice(filename: "虚构发票.pdf", excerpt: content, context: context, config: Configuration())
            XCTAssertEqual(result?.folder, "10月差旅/出差报销/" + expected, result?.reason ?? "未识别为票据")
        }
    }
}

final class InvoiceClassifierTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [InvoiceProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func payload(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func context() throws -> InvoiceContext {
        try InvoiceContext(sourceFolder: URL(fileURLWithPath: "/private/secret/path/10月差旅"),
            relativeFolder: "上海/酒店", purpose: "出差报销", categories: ["交通", "住宿", "餐饮"])
    }
    private func reply(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }
    func testInvoiceUsesFolderPurposeAndAllowedTypesWithoutAbsoluteSourcePath() async throws {
        let transport = session(); defer { transport.invalidateAndCancel() }
        InvoiceProtocol.handler = { request in
            let payload = try self.payload(request)
            let messages = payload["messages"] as! [[String: String]]
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
            XCTAssertEqual(input["来源文件夹"] as? String, "10月差旅")
            XCTAssertEqual(input["原子文件夹"] as? String, "上海/酒店")
            XCTAssertEqual(input["用户填写用途"] as? String, "出差报销")
            XCTAssertTrue((input["票据内容"] as? String)?.contains("虚构住宿发票") == true)
            XCTAssertFalse(messages[1]["content"]!.contains("/private/secret"))
            let format = payload["response_format"] as! [String: Any]
            let schema = (format["json_schema"] as! [String: Any])["schema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            XCTAssertEqual((properties["category_id"] as! [String: Any])["enum"] as? [Int], [-1, 0, 1, 2])
            return try self.reply(#"{"is_invoice":true,"purpose":"其他用途","purpose_confident":true,"category_id":1,"confident":true,"reason":"住宿服务"}"#)
        }
        let result = try await RemoteClassifier.invoice(filename: "001.pdf", excerpt: "虚构住宿发票，项目：住宿服务", context: context(), config: Configuration(), transport: transport)
        XCTAssertEqual(result?.folder, "10月差旅/出差报销/住宿")
    }
    func testNonInvoiceIsNotMovedIntoExpenseFolders() async throws {
        let transport = session(); defer { transport.invalidateAndCancel() }
        InvoiceProtocol.handler = { _ in try self.reply(#"{"is_invoice":false,"purpose":"","purpose_confident":false,"category_id":-1,"confident":false,"reason":"普通合同"}"#) }
        let result = try await RemoteClassifier.invoice(filename: "合同.txt", excerpt: "合同条款", context: context(), config: Configuration(), transport: transport)
        XCTAssertNil(result)
    }
    func testInvoiceContextRequiresDirectoryConsentForCloudTransport() async throws {
        let transport = session(); defer { transport.invalidateAndCancel() }
        InvoiceProtocol.handler = { _ in XCTFail("Must not transmit context without directory consent"); return Data() }
        var configuration = Configuration()
        configuration.apiEndpoint = "https://example.com/v1/chat/completions"
        configuration.allowContentUpload = true; configuration.allowDirectoryContextUpload = false
        do {
            _ = try await RemoteClassifier.invoice(filename: "invoice.txt", excerpt: "synthetic", context: context(), config: configuration, transport: transport)
            XCTFail("Expected consent failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("目录线索")) }
    }
}
