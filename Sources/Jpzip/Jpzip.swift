import Foundation

/// Package-level shortcuts wrap a lazily-initialized default `JpzipClient`.
/// They share L1 state but cannot be configured with an L2 cache — use
/// `JpzipClient(...)` to get a configurable instance for that.

private enum DefaultClientHolder {
    static let shared: JpzipClient = JpzipClient()
}

private func dflt() -> JpzipClient {
    DefaultClientHolder.shared
}

/// Shortcut for `JpzipClient().lookup(zipcode)`.
public func lookup(_ zipcode: String) async throws -> ZipcodeEntry? {
    return try await dflt().lookup(zipcode)
}

/// Shortcut for `JpzipClient().lookupGroup(prefix)`.
public func lookupGroup(_ prefix: String) async throws -> ZipcodeDict {
    return try await dflt().lookupGroup(prefix)
}

/// Shortcut for `JpzipClient().lookupAll()`.
public func lookupAll() async throws -> ZipcodeDict {
    return try await dflt().lookupAll()
}

/// Shortcut for `JpzipClient().preload(scope)`.
public func preload(_ scope: String) async throws {
    try await dflt().preload(scope)
}

/// Shortcut for `JpzipClient().getMeta()`.
public func getMeta() async throws -> Meta? {
    return try await dflt().getMeta()
}

/// Shortcut for `JpzipClient().refresh()`.
public func refresh() async throws {
    try await dflt().refresh()
}
