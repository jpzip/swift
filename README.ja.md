# jpzip-swift

[![Swift Package Manager compatible](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2015%20%7C%20macOS%2012%20%7C%20tvOS%2015%20%7C%20watchOS%208-lightgrey.svg)](#必要環境)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Test](https://github.com/jpzip/swift/actions/workflows/test.yml/badge.svg)](https://github.com/jpzip/swift/actions/workflows/test.yml)

> **jpzip** の Swift SDK — 無料・無制限の日本郵便番号 API。
> 日本郵便の `KEN_ALL.csv` / `KEN_ALL_ROME.csv` を JSON 正規化し CDN 配信。

[English](./README.md) | **日本語**

`jpzip-swift` は `jpzip.nadai.dev` から日本の郵便番号 120,677 件を引く Swift SDK です。
登録不要、レート制限なし、API キー不要。

- 🇯🇵 **全件収録** — 漢字・カナ・ローマ字・自治体コード(JIS X 0401 / 総務省地方公共団体コード)
- ⚡️ **高速** — actor 隔離の L1 LRU + 任意の L2 永続キャッシュ。`preload` でネットワーク往復なしのルックアップが可能
- 🛡️ **堅牢** — 5xx / ネットワーク失敗時は指数バックオフで最大 3 回リトライ
- 🪶 **依存ゼロ** — Foundation のみ(既定は `URLSession` バックエンド)
- 🧵 **モダン Swift 並行性** — async/await、`Sendable` 準拠、`actor` 隔離クライアント
- 🆓 **永久無料** — Cloudflare Pages 無料枠で運用(課金軸が存在しない)
- 🔌 **同一 API** — [全 jpzip SDK](#他言語版) で API が揃う

## 必要環境

- Swift 5.9+
- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+

## インストール

`Package.swift` に追加:

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

Xcode の場合は **File → Add Package Dependencies…** から `https://github.com/jpzip/swift.git` を追加。

## クイックスタート

```swift
import Jpzip

if let entry = try await lookup("2310017") {
    print(entry.prefecture, entry.city, entry.towns[0].town)
    // 出力: 神奈川県 横浜市中区 港町
} else {
    print("見つかりません")
}
```

ローマ字・自治体コードも同じエントリに含まれます:

```swift
print(entry.prefectureRoma, entry.cityRoma, entry.towns[0].roma)
// 出力: Kanagawa Ken Yokohama Shi Naka Ku Minatocho

print(entry.prefectureCode, entry.cityCode)
// 出力: 14 14104
```

## ユースケース

### SwiftUI フォームから住所を埋める

`@MainActor` の View モデルから jpzip を呼び、7 桁の郵便番号が入力された
瞬間に都道府県・市区町村・町域フィールドを自動で埋めます。

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
            // バナー等で通知。ユーザーは手入力で継続可能。
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

### 郵便番号ルックアップ HTTP エンドポイント (Vapor)

サーバーサイド Swift (macOS / Linux):

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

### CSV のバッチ検証

```swift
let all = try await lookupAll() // 全件をメモリに展開(JSON 約 37 MiB)
for zip in csvZipcodes {
    if all[zip] == nil {
        print("不正な郵便番号: \(zip)")
    }
}
```

### キャッシュからの提供(任意の L2 バックエンド)

データは 948 個の 3 桁 prefix バケットに分割されています。デフォルト L1 (100 件) は
ホットなバケットを保持しますが、全件を常駐させるには L2 を併用するか
`memoryCacheSize` を 948 超に設定してください。

```swift
let client = JpzipClient(
    memoryCacheSize: 1024,
    cache: myFileCache // `Cache` プロトコルを実装した任意の型
)
try await client.preload("all")
// 以降の lookup は L1/L2 で完結し、ネットワークにアクセスしない。
let entry = try await client.lookup("2310017")
```

## API リファレンス

### パッケージレベル関数(内部の default `JpzipClient` を共有)

| 関数 | 説明 |
|---|---|
| `lookup(_ zipcode:)` | 7 桁の郵便番号で 1 件引く。見つからない / 不正な入力は `nil`(不正入力時はネットワーク不使用)。 |
| `lookupGroup(_ prefix:)` | 1〜3 桁の prefix で引く。1 桁は `/g/{d}.json` を 1 回、3 桁は `/p/{ddd}.json` を 1 回、2 桁は 10 並列 fetch して結合。 |
| `lookupAll()` | `/g/0..9.json` を並列取得して全件(120k 件、約 37 MiB)を返す。 |
| `getMeta()` | データバージョン・生成日時・都道府県別件数・spec version。`refresh()` までは結果をキャッシュ。 |
| `preload(_ scope:)` | `"all"` または特定 prefix で L1(L2 設定時は L2 も)を温める。 |
| `refresh()` | L1(L2 設定時は L2 も)を消し、キャッシュ済み meta を破棄。 |
| `isValidZipcode(_:)` | 純粋な書式チェック(`^\d{7}$`)。ネットワーク不使用。 |

すべての非同期 API は throwing で、`URLSession` のエラーはそのまま伝播し、
SDK レベルのエラーは `JpzipError` として返します。

### `JpzipClient`(高度な用途)

`JpzipClient` は `actor` です。L2 キャッシュ、`HTTPFetcher` 差し替え、
配信元変更、複数の独立キャッシュが必要な場合にインスタンス化:

```swift
let client = JpzipClient(
    baseURL: "https://jpzip.nadai.dev",
    memoryCacheSize: 200,  // L1 容量(prefix バケット数)、デフォルト 100
    cache: myCache,        // L2(任意)
    fetcher: nil,          // 任意の `HTTPFetcher`
    onSpecMismatch: { expected, received in
        print("jpzip spec 不一致: SDK=\(expected) server=\(received)")
    }
)
```

`JpzipClient` はパッケージレベル関数と同じメソッド群
(`lookup` / `lookupGroup` / `lookupAll` / `getMeta` / `preload` / `refresh`)を公開します。

`getMeta()` が `/meta.json` の `version` 変更を検知すると L1/L2 は自動クリアされます。
データ切り替えに追従するには `getMeta()` を定期的に呼んでください。

### エラー

`JpzipError` は enum:

```swift
public enum JpzipError: Error, Sendable, Equatable {
    case invalidPrefix(String)
    case parseError(String)
    case httpError(url: String, status: Int)
}
```

- `.invalidPrefix` は prefix が 1〜3 桁でない場合に `lookupGroup` / `preload` から throw されます。
- ネットワーク失敗と 5xx は最大 3 回試行(初回 + リトライ 2 回)、指数バックオフのスリープは 400ms / 800ms。404 以外の 4xx は即座に throw(404 は `nil` として返却)。

### `Cache` プロトコル

任意の L2 バックエンド(ファイル / Keychain / Core Data / Redis など)を渡せます:

```swift
public protocol Cache: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data) async throws
    func delete(_ key: String) async throws
    func clear() async throws
}
```

キーは prefix バケットの完全 URL(例: `https://jpzip.nadai.dev/p/231.json`)、値は生 JSON バイト列。

### `HTTPFetcher` プロトコル

テストやカスタムトランスポート(独自設定の `URLSession` など)向け:

```swift
public protocol HTTPFetcher: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}
```

既定では `URLSession.shared` を使用します。

## なぜ jpzip-swift か

| | **jpzip-swift** | [Taillook/ZipCode4s][zc4s] | [woxtu/swift-kenall][kenall] | [zipcloud API][zipcloud] |
|---|---|---|---|---|
| ローマ字(`Yokohama Shi`) | ✅ | ❌ | ⚠️ 有料プラン | ❌ |
| 自治体コード(JIS / 総務省) | ✅ | ❌ | ✅ | ❌ |
| API キー不要 | ✅ | ✅ | ❌ 必須 | ✅ |
| 月次更新 | ✅ 自動 | ❌ アーカイブ (2020) | ✅ | ✅ |
| Preload 後オフライン | ✅ | ✅ 埋め込み | ❌ | ❌ |
| SwiftPM | ✅ | ❌ CocoaPods/Carthage | ✅ | n/a |
| async/await + `Sendable` | ✅ | ❌ | ✅ | n/a |
| L1 + 差し替え可能な L2 | ✅ | n/a | ❌ | ❌ |
| レート制限なし | ✅ | ✅ | ⚠️ プラン制クォータ | ⚠️ 大量アクセス非推奨 |
| 依存ゼロ | ✅ | ✅ | ✅ | n/a |

[zc4s]: https://github.com/Taillook/ZipCode4s
[kenall]: https://github.com/woxtu/swift-kenall
[zipcloud]: http://zipcloud.ibsnet.co.jp/doc/api

## 他言語版

全 SDK で同一の API を提供しています:

[Go](https://github.com/jpzip/go) · [TypeScript](https://github.com/jpzip/js) · [Python](https://github.com/jpzip/python) · [Rust](https://github.com/jpzip/rust) · [Ruby](https://github.com/jpzip/ruby) · [PHP](https://github.com/jpzip/php) · [Dart](https://github.com/jpzip/dart)

## 関連リソース

- **Web サイト** — https://jpzip.nadai.dev
- **プロトコル仕様** — [jpzip/spec](https://github.com/jpzip/spec)
- **データ ETL** — [jpzip/data](https://github.com/jpzip/data)
- **MCP サーバー** — [jpzip/mcp](https://github.com/jpzip/mcp) — Claude / ChatGPT / Cursor から jpzip を呼ぶ

## キーワード

日本郵便番号, 郵便番号, KEN_ALL, KEN_ALL_ROME, 住所検索, 住所自動補完, 住所バリデーション, SwiftUI 住所フォーム, iOS 郵便番号, japanese postal code, japan zipcode, swift japanese address, JIS X 0401, 総務省地方公共団体コード

## ライセンス

[MIT](./LICENSE)
