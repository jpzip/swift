import Foundation

/// The jpzip protocol version this SDK targets.
public let SpecVersion = "1.0"

/// Production CDN origin.
public let DefaultBaseURL = "https://jpzip.nadai.dev"

/// One element of `ZipcodeEntry.towns`.
public struct Town: Codable, Sendable, Equatable, Hashable {
    public let town: String
    public let kana: String
    public let roma: String
    public let note: String?

    public init(town: String, kana: String, roma: String, note: String? = nil) {
        self.town = town
        self.kana = kana
        self.roma = roma
        self.note = note
    }
}

/// One logical entry as published by the CDN.
public struct ZipcodeEntry: Codable, Sendable, Equatable, Hashable {
    public let prefecture: String
    public let prefectureKana: String
    public let prefectureRoma: String
    public let prefectureCode: String
    public let city: String
    public let cityKana: String
    public let cityRoma: String
    public let cityCode: String
    public let towns: [Town]

    enum CodingKeys: String, CodingKey {
        case prefecture
        case prefectureKana = "prefecture_kana"
        case prefectureRoma = "prefecture_roma"
        case prefectureCode = "prefecture_code"
        case city
        case cityKana = "city_kana"
        case cityRoma = "city_roma"
        case cityCode = "city_code"
        case towns
    }

    public init(
        prefecture: String,
        prefectureKana: String,
        prefectureRoma: String,
        prefectureCode: String,
        city: String,
        cityKana: String,
        cityRoma: String,
        cityCode: String,
        towns: [Town]
    ) {
        self.prefecture = prefecture
        self.prefectureKana = prefectureKana
        self.prefectureRoma = prefectureRoma
        self.prefectureCode = prefectureCode
        self.city = city
        self.cityKana = cityKana
        self.cityRoma = cityRoma
        self.cityCode = cityCode
        self.towns = towns
    }
}

/// The on-the-wire shape of `/g/*.json` and `/p/*.json`.
public typealias ZipcodeDict = [String: ZipcodeEntry]

/// Part of `/meta.json`.
public struct Endpoints: Codable, Sendable, Equatable, Hashable {
    public let group: String
    public let prefix: String

    public init(group: String, prefix: String) {
        self.group = group
        self.prefix = prefix
    }
}

/// `/meta.json`.
public struct Meta: Codable, Sendable, Equatable, Hashable {
    public let version: String
    public let generatedAt: String
    public let specVersion: String
    public let totalZipcodes: Int
    public let prefixCount: Int
    public let byPref: [String: Int]
    public let dataSource: String
    public let endpoints: Endpoints

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case specVersion = "spec_version"
        case totalZipcodes = "total_zipcodes"
        case prefixCount = "prefix_count"
        case byPref = "by_pref"
        case dataSource = "data_source"
        case endpoints
    }

    public init(
        version: String,
        generatedAt: String,
        specVersion: String,
        totalZipcodes: Int,
        prefixCount: Int,
        byPref: [String: Int],
        dataSource: String,
        endpoints: Endpoints
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.specVersion = specVersion
        self.totalZipcodes = totalZipcodes
        self.prefixCount = prefixCount
        self.byPref = byPref
        self.dataSource = dataSource
        self.endpoints = endpoints
    }
}

/// Error type for invalid inputs.
public enum JpzipError: Error, Sendable, Equatable {
    case invalidPrefix(String)
    case parseError(String)
    case httpError(url: String, status: Int)
}

/// Reports whether a string syntactically looks like a 7-digit zipcode.
public func isValidZipcode(_ s: String) -> Bool {
    guard s.count == 7 else { return false }
    return s.allSatisfy { $0.isASCII && $0.isNumber }
}

@inlinable
func isValidPrefix(_ s: String) -> Bool {
    let n = s.count
    guard n >= 1, n <= 3 else { return false }
    return s.allSatisfy { $0.isASCII && $0.isNumber }
}
