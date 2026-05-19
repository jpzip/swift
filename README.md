# jpzip-swift

[![Swift Package Manager compatible](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2015%20%7C%20macOS%2012%20%7C%20tvOS%2015%20%7C%20watchOS%208-lightgrey.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Test](https://github.com/jpzip/swift/actions/workflows/test.yml/badge.svg)](https://github.com/jpzip/swift/actions/workflows/test.yml)
[![Docs](https://img.shields.io/badge/docs-jpzip.nadai.dev-0066cc.svg)](https://jpzip.nadai.dev)

> Swift SDK for **jpzip** — a free, unlimited Japanese postal code (郵便番号) API.
> 日本の全郵便番号 120,677 件を CDN 配信 JSON から引く Swift SDK。

**English** | [日本語](./README.ja.md)

`jpzip-swift` looks up Japanese postal codes (郵便番号) from `jpzip.nadai.dev`,
a CDN-hosted dataset built from Japan Post's `KEN_ALL.csv` and `KEN_ALL_ROME.csv`
normalized to JSON. No registration, no rate limits, no API key.

- 🇯🇵 **Complete dataset** — 120,677 entries with kanji, kana, romaji, and government codes (JIS X 0401 / 総務省地方公共団体コード)
- ⚡️ **Fast** — actor-isolated L1 LRU + optional L2 persistent cache; `preload` to serve lookups without per-request network round-trips
- 🛡️ **Resilient** — 3-attempt retry with exponential backoff on 5xx / network failures
- 🪶 **Zero deps** — Foundation only (URLSession-backed by default)
- 🧵 **Modern concurrency** — async/await, `Sendable`-clean, `actor`-isolated client
- 🆓 **Free forever** — backed by Cloudflare Pages' free tier (no billing axis exists)
- 🔌 **Drop-in** — same API surface across [every jpzip SDK](#other-languages)

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+

## Install

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jpzip/swift.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Jpzip", package: "swift"),
        ]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** → `https://github.com/jpzip/swift.git`.

## Quick Start

```swift
import Jpzip

if let entry = try await lookup("2310017") {
    print(entry.prefecture, entry.city, entry.towns[0].town)
    // Output: 神奈川県 横浜市中区 港町
} else {
    print("not found")
}
```

Romaji and government codes are included on the same entry:

```swift
print(entry.prefectureRoma, entry.cityRoma, entry.towns[0].roma)
// Output: Kanagawa Ken Yokohama Shi Naka Ku Minatocho

print(entry.prefectureCode, entry.cityCode)
// Output: 14 14104
```

## Use Cases

### Filling an address form from a SwiftUI view-model

Call jpzip from a `@MainActor` view-model to populate prefecture / city / town
fields the moment the user finishes typing a 7-digit zipcode.

```swift
import SwiftUI
import Jpzip

@MainActor
final class AddressFormModel: ObservableObject {
    @Published var zipcode = ""
    @Published var prefecture = ""
    @Published var city = ""
    @Published var town = ""

    func zipcodeChanged() async {
        guard isValidZipcode(zipcode) else { return }
        do {
            if let entry = try await lookup(zipcode) {
                prefecture = entry.prefecture
                city = entry.city
                town = entry.towns.first?.town ?? ""
            }
        } catch {
            // surface as a non-fatal banner; the user can still type manually
        }
    }
}

struct AddressForm: View {
    @StateObject private var model = AddressFormModel()

    var body: some View {
        Form {
            TextField("郵便番号 (7桁)", text: $model.zipcode)
                .keyboardType(.numberPad)
                .onChange(of: model.zipcode) { _ in
                    Task { await model.zipcodeChanged() }
                }
            TextField("都道府県", text: $model.prefecture)
            TextField("市区町村", text: $model.city)
            TextField("町域", text: $model.town)
        }
    }
}
```

### Zipcode lookup HTTP endpoint (Vapor)

For server-side Swift on macOS / Linux:

```swift
import Vapor
import Jpzip

func routes(_ app: Application) throws {
    app.get("api", "zipcode", ":code") { req async throws -> Response in
        let code = req.parameters.get("code") ?? ""
        guard let entry = try await lookup(code) else {
            throw Abort(.notFound)
        }
        return try await entry.encodeResponse(for: req)
    }
}
```

### Batch validation

```swift
let all = try await lookupAll() // entire dataset in memory (~37 MiB JSON)
for zip in csvZipcodes {
    if all[zip] == nil {
        print("invalid zipcode: \(zip)")
    }
}
```

### Serve lookups from cache (BYO L2 backend)

The dataset is partitioned into 948 three-digit prefix buckets. The default
L1 (100 entries) keeps the hottest buckets; to cache the whole dataset, pair
`preload("all")` with an L2 cache or raise `memoryCacheSize` above 948.

```swift
let client = JpzipClient(
    memoryCacheSize: 1024,
    cache: myFileCache // any `Cache` conformer
)
try await client.preload("all")
// Subsequent lookups are served from L1/L2 without hitting the network.
let entry = try await client.lookup("2310017")
```

## API Reference

### Package-level functions (share a default `JpzipClient`)

| Function | Description |
|---|---|
| `lookup(_ zipcode:)` | Look up a single 7-digit zipcode. Returns `nil` if not found or malformed (no network call for malformed input). |
| `lookupGroup(_ prefix:)` | Look up by 1-, 2-, or 3-digit prefix. 1-digit fetches `/g/{d}.json`; 3-digit fetches `/p/{ddd}.json`; 2-digit fans out into 10 parallel 3-digit fetches and merges. |
| `lookupAll()` | Fetch entire dataset (120k entries, ~37 MiB) in parallel across `/g/0..9.json`. |
| `getMeta()` | Dataset version, generated-at, per-prefecture counts, spec version. Result is cached until `refresh()`. |
| `preload(_ scope:)` | Warm L1 (and L2 when configured) for `"all"` or a specific prefix. |
| `refresh()` | Wipe L1 (and L2 when configured) and forget the cached meta. |
| `isValidZipcode(_:)` | Pure syntax check (`^\d{7}$`) — no network. |

All async functions are throwing; `URLSession` errors propagate as Swift errors,
and SDK-level errors are surfaced as `JpzipError`.

### `JpzipClient` (advanced)

`JpzipClient` is an `actor`. Initialize one for L2 caching, custom HTTP
fetcher, alternate base URL, or multiple isolated caches:

```swift
let client = JpzipClient(
    baseURL: "https://jpzip.nadai.dev",
    memoryCacheSize: 200,  // L1 capacity in prefix buckets, default 100
    cache: myCache,        // optional L2
    fetcher: nil,          // optional custom `HTTPFetcher`
    onSpecMismatch: { expected, received in
        print("jpzip spec mismatch: SDK=\(expected) server=\(received)")
    }
)
```

`JpzipClient` exposes the same method set as the package-level functions
(`lookup` / `lookupGroup` / `lookupAll` / `getMeta` / `preload` / `refresh`).

When `getMeta()` observes that `/meta.json`'s `version` has changed since the
last successful fetch, L1 and L2 are cleared automatically — call `getMeta()`
periodically to pick up dataset rollovers.

### Errors

`JpzipError` is an `enum`:

```swift
public enum JpzipError: Error, Sendable, Equatable {
    case invalidPrefix(String)
    case parseError(String)
    case httpError(url: String, status: Int)
}
```

- `.invalidPrefix` is thrown by `lookupGroup` / `preload` when the prefix is not 1–3 digits.
- Transient network failures and 5xx responses are retried up to 3 attempts (initial + 2 retries) with exponential backoff sleeps of 400 ms and 800 ms. 4xx responses (other than 404, which yields `nil`) are thrown immediately.

### `Cache` protocol

Bring your own L2 backend (file, Keychain, Core Data, Redis, etc.):

```swift
public protocol Cache: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data) async throws
    func delete(_ key: String) async throws
    func clear() async throws
}
```

Keys are the full prefix-bucket URLs (e.g. `https://jpzip.nadai.dev/p/231.json`);
values are raw JSON bytes.

### `HTTPFetcher` protocol

For tests or custom transports (e.g. `URLSession` with a configured delegate):

```swift
public protocol HTTPFetcher: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}
```

The default fetcher uses `URLSession.shared`.

## Why jpzip-swift?

| | **jpzip-swift** | [Taillook/ZipCode4s][zc4s] | [woxtu/swift-kenall][kenall] | [zipcloud API][zipcloud] |
|---|---|---|---|---|
| Romaji (`Yokohama Shi`) | ✅ | ❌ | ⚠️ Paid plans | ❌ |
| Government codes (JIS / 総務省) | ✅ | ❌ | ✅ | ❌ |
| No API key | ✅ | ✅ | ❌ Required | ✅ |
| Monthly updates | ✅ Auto | ❌ Archived (2020) | ✅ | ✅ |
| Offline after preload | ✅ | ✅ Embedded | ❌ | ❌ |
| SwiftPM | ✅ | ❌ CocoaPods/Carthage | ✅ | n/a |
| async/await + `Sendable` | ✅ | ❌ | ✅ | n/a |
| L1 + pluggable L2 cache | ✅ | n/a | ❌ | ❌ |
| Rate-limit-free | ✅ | ✅ | ⚠️ Plan-based quota | ⚠️ Discouraged |
| Zero dependencies | ✅ | ✅ | ✅ | n/a |

[zc4s]: https://github.com/Taillook/ZipCode4s
[kenall]: https://github.com/woxtu/swift-kenall
[zipcloud]: http://zipcloud.ibsnet.co.jp/doc/api

## Other Languages

Same API surface across all SDKs:

[Go](https://github.com/jpzip/go) · [TypeScript](https://github.com/jpzip/js) · [Python](https://github.com/jpzip/python) · [Rust](https://github.com/jpzip/rust) · [Ruby](https://github.com/jpzip/ruby) · [PHP](https://github.com/jpzip/php) · [Dart](https://github.com/jpzip/dart)

## Resources

- **Website** — https://jpzip.nadai.dev
- **Protocol spec** — [jpzip/spec](https://github.com/jpzip/spec)
- **Data ETL** — [jpzip/data](https://github.com/jpzip/data)
- **MCP server** — [jpzip/mcp](https://github.com/jpzip/mcp) — use jpzip from Claude / ChatGPT / Cursor

## Keywords

japanese postal code, japan zipcode, 郵便番号, KEN_ALL, KEN_ALL_ROME, address validation, address autocomplete, japan address api, postal code lookup swift, swift japanese address, swiftui address form, ios postal code, JIS X 0401, 総務省地方公共団体コード

## License

[MIT](./LICENSE)
