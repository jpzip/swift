import Foundation

/// Hook invoked once if `/meta.json`'s `spec_version` differs from `SpecVersion`.
public typealias OnSpecMismatch = @Sendable (_ expected: String, _ received: String) -> Void

/// The jpzip SDK entry point. Thread-safe via actor isolation.
public actor JpzipClient {
    private let baseURL: String
    private let fetcher: HTTPFetcher
    private let cache: Cache?
    private let onSpecMismatch: OnSpecMismatch?
    private let mem: MemoryLRU

    // Meta state.
    private var metaCached: Meta?
    private var metaResolved: Bool = false
    private var knownVersion: String = ""
    private var specMismatchFired: Bool = false

    public init(
        baseURL: String = DefaultBaseURL,
        memoryCacheSize: Int = 100,
        cache: Cache? = nil,
        fetcher: HTTPFetcher? = nil,
        onSpecMismatch: OnSpecMismatch? = nil
    ) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.mem = MemoryLRU(capacity: memoryCacheSize)
        self.cache = cache
        self.fetcher = fetcher ?? URLSessionFetcher()
        self.onSpecMismatch = onSpecMismatch
    }

    /// Returns the entry for `zipcode`, or `nil` if not found.
    /// Malformed input returns `nil` without contacting the network.
    public func lookup(_ zipcode: String) async throws -> ZipcodeEntry? {
        guard isValidZipcode(zipcode) else { return nil }
        let prefix3 = String(zipcode.prefix(3))
        guard let dict = try await fetchPrefixDict(prefix3) else {
            return nil
        }
        return dict[zipcode]
    }

    /// Fetches all entries under a 1-, 2-, or 3-digit prefix.
    /// A 2-digit prefix fans out into 10 prefix-3 fetches.
    public func lookupGroup(_ prefix: String) async throws -> ZipcodeDict {
        guard isValidPrefix(prefix) else {
            throw JpzipError.invalidPrefix(prefix)
        }
        switch prefix.count {
        case 3:
            return try await fetchPrefixDict(prefix) ?? [:]
        case 1:
            return try await fetchURL(baseURL + "/g/" + prefix + ".json") ?? [:]
        case 2:
            return try await withThrowingTaskGroup(of: ZipcodeDict?.self) { group in
                for i in 0..<10 {
                    let p = "\(prefix)\(i)"
                    group.addTask { [self] in
                        try await fetchPrefixDict(p)
                    }
                }
                var out = ZipcodeDict()
                for try await d in group {
                    if let d = d {
                        for (k, v) in d { out[k] = v }
                    }
                }
                return out
            }
        default:
            throw JpzipError.invalidPrefix(prefix)
        }
    }

    /// Fetches the full dataset by fanning out across `/g/0..9.json`.
    public func lookupAll() async throws -> ZipcodeDict {
        return try await withThrowingTaskGroup(of: ZipcodeDict?.self) { group in
            for i in 0..<10 {
                let url = "\(baseURL)/g/\(i).json"
                group.addTask { [self] in
                    try await fetchURL(url)
                }
            }
            var out = ZipcodeDict()
            for try await d in group {
                if let d = d {
                    for (k, v) in d { out[k] = v }
                }
            }
            return out
        }
    }

    /// Returns the cached `/meta.json`. The first call hits the network;
    /// subsequent calls reuse the result until `refresh()` is called.
    public func getMeta() async throws -> Meta? {
        if metaResolved {
            return metaCached
        }
        let (body, status) = try await getRaw(fetcher: fetcher, urlString: baseURL + "/meta.json")
        if status == 404 {
            metaResolved = true
            return nil
        }
        guard let body = body else {
            metaResolved = true
            return nil
        }
        let decoder = JSONDecoder()
        let m: Meta
        do {
            m = try decoder.decode(Meta.self, from: body)
        } catch {
            throw JpzipError.parseError("meta: \(error)")
        }
        if m.specVersion != SpecVersion, !specMismatchFired, let hook = onSpecMismatch {
            specMismatchFired = true
            hook(SpecVersion, m.specVersion)
        }
        if !knownVersion.isEmpty, knownVersion != m.version {
            await mem.clear()
            if let cache = cache {
                try await cache.clear()
            }
        }
        knownVersion = m.version
        metaCached = m
        metaResolved = true
        return m
    }

    /// Pulls the requested scope into L1 (and L2 when configured).
    /// `scope == "all"` downloads `/g/0..9.json`; otherwise it must be a valid prefix.
    public func preload(_ scope: String) async throws {
        if scope == "all" {
            let dict = try await lookupAll()
            // Bucket by 3-digit prefix and seed L1 + L2.
            var buckets: [String: ZipcodeDict] = [:]
            for (zip, e) in dict {
                let p = String(zip.prefix(3))
                buckets[p, default: [:]][zip] = e
            }
            for (p, b) in buckets {
                let url = prefixURL(p)
                await mem.set(url, b)
                try await writeL2(url: url, dict: b)
            }
            return
        }
        guard isValidPrefix(scope) else {
            throw JpzipError.invalidPrefix(scope)
        }
        _ = try await lookupGroup(scope)
    }

    /// Wipes L1 (and L2 when configured) and forgets the cached meta.
    public func refresh() async throws {
        await mem.clear()
        metaCached = nil
        metaResolved = false
        knownVersion = ""
        specMismatchFired = false
        if let cache = cache {
            try await cache.clear()
        }
    }

    // MARK: - internals

    private func prefixURL(_ prefix3: String) -> String {
        return baseURL + "/p/" + prefix3 + ".json"
    }

    private func fetchPrefixDict(_ prefix3: String) async throws -> ZipcodeDict? {
        let url = prefixURL(prefix3)
        if let d = await mem.get(url) {
            return d
        }
        if let d = try await readL2(url: url) {
            await mem.set(url, d)
            return d
        }
        guard let d = try await fetchURL(url) else {
            return nil
        }
        await mem.set(url, d)
        try await writeL2(url: url, dict: d)
        return d
    }

    private func fetchURL(_ url: String) async throws -> ZipcodeDict? {
        let (body, status) = try await getRaw(fetcher: fetcher, urlString: url)
        if status == 404 {
            return nil
        }
        guard let body = body else { return nil }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ZipcodeDict.self, from: body)
        } catch {
            throw JpzipError.parseError("\(url): \(error)")
        }
    }

    private func readL2(url: String) async throws -> ZipcodeDict? {
        guard let cache = cache else { return nil }
        guard let data = try await cache.get(url) else { return nil }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ZipcodeDict.self, from: data)
        } catch {
            // Corrupt cache — drop it.
            try? await cache.delete(url)
            return nil
        }
    }

    private func writeL2(url: String, dict: ZipcodeDict) async throws {
        guard let cache = cache else { return }
        let encoder = JSONEncoder()
        let data = try encoder.encode(dict)
        try await cache.set(url, data)
    }
}
