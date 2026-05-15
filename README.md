# jpzip — Swift SDK

> 日本の郵便番号を CDN 配信の JSON データから引く Swift SDK。

- 配信ドメイン: `https://jpzip.nadai.dev`
- プロトコル仕様: [`jpzip/spec`](https://github.com/jpzip/spec)
- データ ETL: [`jpzip/data`](https://github.com/jpzip/data)

## インストール

SwiftPM:

```swift
// Package.swift
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

対応プラットフォーム: iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+ / Swift 5.9+

## 使い方

### 関数 API

```swift
import Jpzip

if let entry = try await lookup("2310831") {
    print(entry.prefecture)  // 神奈川県
    print(entry.city)        // 横浜市中区
}
// entry == nil なら見つからなかった

let dict = try await lookupGroup("23")  // 2 桁は 10 並列 fetch
let all  = try await lookupAll()
let meta = try await getMeta()
```

### クライアント API (L2 キャッシュ・複数インスタンス用)

```swift
import Jpzip

let client = JpzipClient(
    baseURL: "https://jpzip.nadai.dev",
    memoryCacheSize: 200,
    cache: myCache,  // Cache プロトコル を実装
    onSpecMismatch: { expected, received in
        print("spec mismatch: expected=\(expected) received=\(received)")
    }
)

try await client.preload("all")
let entry = try await client.lookup("2310831")
```

## Cache プロトコル

```swift
public protocol Cache: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data) async throws
    func delete(_ key: String) async throws
    func clear() async throws
}
```

ファイル / KeychainStore / Core Data / Redis 等の任意の実装を渡せる。

## 入力検証

`lookup(_:)` は `^\d{7}$` にマッチしない入力には fetch せず `nil` を返す。

`isValidZipcode(_:)` でフォーマット検証のみ行える。

## バージョン整合性

`getMeta()` で `spec_version` が異なる場合、`onSpecMismatch` で渡したコールバックが 1 度だけ呼ばれる。データバージョンが変わったら L1/L2 を自動 invalidate する。

## ライセンス

[MIT](./LICENSE)
