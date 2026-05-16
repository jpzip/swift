import XCTest
@testable import Jpzip

/// In-memory stub fetcher. Maps URL → (data, status).
final class StubFetcher: HTTPFetcher, @unchecked Sendable {
    struct Response {
        let data: Data
        let status: Int
    }
    private let lock = NSLock()
    private var routes: [String: Response] = [:]
    private(set) var callLog: [String] = []
    /// First N calls per URL fail with a network error (count is decremented per call).
    private var failuresRemaining: [String: Int] = [:]

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func set(_ url: String, status: Int, json: String) {
        withLock { routes[url] = Response(data: Data(json.utf8), status: status) }
    }

    func setData(_ url: String, status: Int, data: Data) {
        withLock { routes[url] = Response(data: data, status: status) }
    }

    func failNext(_ url: String, times: Int) {
        withLock { failuresRemaining[url] = times }
    }

    func callCount(_ url: String) -> Int {
        withLock { callLog.filter { $0 == url }.count }
    }

    func totalCalls() -> Int {
        withLock { callLog.count }
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        let s = url.absoluteString
        enum LookupResult {
            case fail
            case response(Response)
            case notFound
        }
        let result: LookupResult = withLock {
            callLog.append(s)
            if let n = failuresRemaining[s], n > 0 {
                failuresRemaining[s] = n - 1
                return .fail
            }
            if let r = routes[s] {
                return .response(r)
            }
            return .notFound
        }
        switch result {
        case .fail:
            throw NSError(domain: "stub", code: -1)
        case .response(let r):
            return (r.data, r.status)
        case .notFound:
            return (Data(), 404)
        }
    }
}

private let sampleEntryJSON = """
{
  "2310017": {
    "prefecture": "神奈川県",
    "prefecture_kana": "カナガワケン",
    "prefecture_roma": "Kanagawa",
    "prefecture_code": "14",
    "city": "横浜市中区",
    "city_kana": "ヨコハマシナカク",
    "city_roma": "Yokohama Shi Naka Ku",
    "city_code": "14104",
    "towns": [
      {"town": "本町", "kana": "ホンチョウ", "roma": "Honcho"}
    ]
  }
}
"""

private let metaJSON = """
{
  "version": "2026-05",
  "generated_at": "2026-05-01T00:00:00Z",
  "spec_version": "1.0",
  "total_zipcodes": 1,
  "prefix_count": 1,
  "by_pref": {"14": 1},
  "data_source": "https://example.com",
  "endpoints": {"group": "/g/{prefix1}.json", "prefix": "/p/{prefix3}.json"}
}
"""

final class JpzipClientTests: XCTestCase {

    func testIsValidZipcode() {
        XCTAssertTrue(isValidZipcode("2310017"))
        XCTAssertFalse(isValidZipcode("231083"))
        XCTAssertFalse(isValidZipcode("23100171"))
        XCTAssertFalse(isValidZipcode("231083a"))
        XCTAssertFalse(isValidZipcode(""))
    }

    func testLookupMalformedReturnsNilWithoutFetch() async throws {
        let stub = StubFetcher()
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let result = try await client.lookup("123")
        XCTAssertNil(result)
        XCTAssertEqual(stub.totalCalls(), 0)
    }

    func testLookupSuccess() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let entry = try await client.lookup("2310017")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.prefecture, "神奈川県")
        XCTAssertEqual(entry?.prefectureRoma, "Kanagawa")
        XCTAssertEqual(entry?.towns.first?.town, "本町")
    }

    func testLookupCachesPrefixDict() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        _ = try await client.lookup("2310017")
        _ = try await client.lookup("2310017")
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 1)
    }

    func testLookupReturnsNilOn404() async throws {
        let stub = StubFetcher()
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let entry = try await client.lookup("9999999")
        XCTAssertNil(entry)
    }

    func testLookupGroup3Digit() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let dict = try await client.lookupGroup("231")
        XCTAssertEqual(dict.count, 1)
        XCTAssertNotNil(dict["2310017"])
    }

    func testLookupGroup1Digit() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/g/2.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let dict = try await client.lookupGroup("2")
        XCTAssertEqual(dict.count, 1)
    }

    func testLookupGroup2DigitFanout() async throws {
        let stub = StubFetcher()
        // Populate 23x for x in 0..9 with one entry each.
        for i in 0..<10 {
            let zip = "23\(i)0000"
            let body = """
            {"\(zip)": {"prefecture":"P","prefecture_kana":"K","prefecture_roma":"R","prefecture_code":"00","city":"C","city_kana":"CK","city_roma":"CR","city_code":"00000","towns":[{"town":"T","kana":"K","roma":"R"}]}}
            """
            stub.set("https://example.com/p/23\(i).json", status: 200, json: body)
        }
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let dict = try await client.lookupGroup("23")
        XCTAssertEqual(dict.count, 10)
        // Verify all 10 prefix-3 endpoints were called.
        for i in 0..<10 {
            XCTAssertEqual(stub.callCount("https://example.com/p/23\(i).json"), 1)
        }
    }

    func testLookupGroupInvalidPrefix() async throws {
        let stub = StubFetcher()
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        do {
            _ = try await client.lookupGroup("abc")
            XCTFail("expected error")
        } catch let e as JpzipError {
            if case .invalidPrefix = e { /* ok */ } else { XCTFail("wrong case") }
        }
    }

    func testLookupAll() async throws {
        let stub = StubFetcher()
        for i in 0..<10 {
            let zip = "\(i)000000"
            let body = """
            {"\(zip)": {"prefecture":"P","prefecture_kana":"K","prefecture_roma":"R","prefecture_code":"00","city":"C","city_kana":"CK","city_roma":"CR","city_code":"00000","towns":[{"town":"T","kana":"K","roma":"R"}]}}
            """
            stub.set("https://example.com/g/\(i).json", status: 200, json: body)
        }
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let dict = try await client.lookupAll()
        XCTAssertEqual(dict.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(stub.callCount("https://example.com/g/\(i).json"), 1)
        }
    }

    func testGetMetaCachesResult() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/meta.json", status: 200, json: metaJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let m1 = try await client.getMeta()
        let m2 = try await client.getMeta()
        XCTAssertEqual(m1?.version, "2026-05")
        XCTAssertEqual(m2?.version, "2026-05")
        XCTAssertEqual(stub.callCount("https://example.com/meta.json"), 1)
    }

    func testSpecMismatchHookFiresOnce() async throws {
        let stub = StubFetcher()
        let altMeta = metaJSON.replacingOccurrences(of: "\"1.0\"", with: "\"2.0\"")
        stub.set("https://example.com/meta.json", status: 200, json: altMeta)
        let countBox = Counter()
        let client = JpzipClient(
            baseURL: "https://example.com",
            fetcher: stub,
            onSpecMismatch: { _, _ in countBox.increment() }
        )
        _ = try await client.getMeta()
        _ = try await client.getMeta()
        XCTAssertEqual(countBox.value, 1)
    }

    func testRefreshClearsL1() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        _ = try await client.lookup("2310017")
        try await client.refresh()
        _ = try await client.lookup("2310017")
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 2)
    }

    func testRetryOn5xx() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        stub.failNext("https://example.com/p/231.json", times: 1)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        let entry = try await client.lookup("2310017")
        XCTAssertNotNil(entry)
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 2)
    }

    func testNoRetryOn4xx() async throws {
        // Regression: a 403 must throw immediately, not consume the 3-attempt
        // retry budget. If it ever did, the call count would be 3.
        let stub = StubFetcher()
        stub.set("https://example.com/p/231.json", status: 403, json: "{}")
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        do {
            _ = try await client.lookup("2310017")
            XCTFail("expected JpzipError.httpError")
        } catch let err as JpzipError {
            switch err {
            case .httpError(_, let status):
                XCTAssertEqual(status, 403)
            default:
                XCTFail("unexpected error: \(err)")
            }
        }
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 1)
    }

    func testDataVersionChangeInvalidatesCache() async throws {
        let stub = StubFetcher()
        stub.set("https://example.com/meta.json", status: 200, json: metaJSON)
        stub.set("https://example.com/p/231.json", status: 200, json: sampleEntryJSON)
        let client = JpzipClient(baseURL: "https://example.com", fetcher: stub)
        _ = try await client.getMeta()
        _ = try await client.lookup("2310017")
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 1)

        // Switch meta to a new data version, refresh meta cache, refetch.
        let v2 = metaJSON.replacingOccurrences(of: "2026-05", with: "2026-06")
        stub.set("https://example.com/meta.json", status: 200, json: v2)
        try await client.refresh()
        _ = try await client.getMeta()
        _ = try await client.lookup("2310017")
        // After refresh L1 was cleared, so prefix dict should refetch.
        XCTAssertEqual(stub.callCount("https://example.com/p/231.json"), 2)
    }
}

/// Tiny thread-safe counter for hook tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
