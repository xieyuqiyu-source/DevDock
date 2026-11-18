import Foundation
import CoreServices
import CryptoKit

struct SoftwareUpdate: Equatable {
    static let archiveName = "DevDock-macOS-universal.zip"
    private static let latestURL = URL(string: "https://api.github.com/repos/xieyuqiyu-source/DevDock/releases/latest")!

    let tag: String
    let digest: String

    var downloadURL: URL {
        URL(string: "https://github.com/xieyuqiyu-source/DevDock/releases/download")!
            .appendingPathComponent(tag).appendingPathComponent(Self.archiveName)
    }

    static func latest(current: String) async throws -> Self? {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
        return try available(in: data, current: current)
    }

    static func available(in data: Data, current: String) throws -> Self? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let digest: String?
            }
            let tag_name: String
            let assets: [Asset]
        }
        func components(_ version: String) throws -> [UInt] {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw AppError.message("无法识别版本号：\(version)") }
            return try parts.map { part in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt(part) else {
                    throw AppError.message("无法识别版本号：\(version)")
                }
                return value
            }
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard try components(current).lexicographicallyPrecedes(components(version)) else { return nil }
        guard let digest = release.assets.first(where: { $0.name == archiveName })?.digest,
              digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AppError.message("此版本缺少通用安装包或 SHA-256 校验值，请稍后再试。")
        }
        return Self(tag: release.tag_name, digest: digest)
    }

    func download(to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.requireSuccess(response)
        try saveVerified(temporary, to: destination)
    }

    func saveVerified(_ file: URL, to destination: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "sha256:\(hash)" else { throw AppError.message("安装包校验失败，请重新下载。") }
        let files = FileManager.default
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: staging) }
        var archive = staging.appendingPathComponent(Self.archiveName)
        try files.copyItem(at: file, to: archive)
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                       kLSQuarantineDataURLKey as String: downloadURL]
        try archive.setResourceValues(values)
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: archive, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: archive, to: destination)
        }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppError.message("GitHub 请求失败（HTTP \(code)），请稍后重试。")
        }
    }
}
