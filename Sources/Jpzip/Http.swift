import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction so tests can inject a custom data fetcher.
public protocol HTTPFetcher: Sendable {
    /// Returns (data, statusCode). Throws on network failures.
    func get(_ url: URL) async throws -> (Data, Int)
}

/// Default fetcher backed by `URLSession.shared`.
struct URLSessionFetcher: HTTPFetcher {
    func get(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw JpzipError.httpError(url: url.absoluteString, status: -1)
        }
        return (data, http.statusCode)
    }
}

/// Performs `GET url` with bounded retries on 5xx / network failures.
/// Returns `(data, status)` on success. 404 returns `(nil, 404)` so callers
/// can distinguish "absent" from "fetch error".
func getRaw(fetcher: HTTPFetcher, urlString: String) async throws -> (Data?, Int) {
    guard let url = URL(string: urlString) else {
        throw JpzipError.httpError(url: urlString, status: -1)
    }
    var lastError: Error?
    for attempt in 0..<3 {
        if attempt > 0 {
            // 200ms * 2^attempt (400ms, 800ms)
            let ns = UInt64(200_000_000) * (UInt64(1) << attempt)
            try? await Task.sleep(nanoseconds: ns)
        }
        do {
            let (data, status) = try await fetcher.get(url)
            if status == 404 {
                return (nil, 404)
            }
            if status >= 500 {
                lastError = JpzipError.httpError(url: urlString, status: status)
                continue
            }
            if status >= 400 {
                throw JpzipError.httpError(url: urlString, status: status)
            }
            return (data, status)
        } catch let err as JpzipError {
            throw err
        } catch {
            lastError = error
            continue
        }
    }
    throw lastError ?? JpzipError.httpError(url: urlString, status: -1)
}
