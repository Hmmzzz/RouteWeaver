import Foundation
import RouteCore
import Darwin

struct SavedProfile: Codable {
    var version = 1
    var countryEnabled = true
    var rules: [RouteRule] = []
    var lastAppliedCount = 0
    var hasApplied = false
    var events: [ActivityEvent] = []
}

enum ProfileStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteWeaver", isDirectory: true)
    }
    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure("配置目录不是安全的普通目录。") }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid() else { throw AppFailure("配置目录所有者不匹配。") }
        guard chmod(directory.path, 0o700) == 0 else { throw AppFailure("无法保护配置目录权限。") }
    }
    static func read() throws -> SavedProfile? {
        let file = directory.appendingPathComponent("profile.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let profile = try JSONDecoder().decode(SavedProfile.self, from: Data(contentsOf: file))
        guard profile.version == 1, profile.rules.count <= 20000 else { throw AppFailure("配置版本或规则数量不受支持。") }
        return profile
    }
    static func save(_ profile: SavedProfile) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(profile)
        try data.write(to: directory.appendingPathComponent("profile.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("profile.json").path)
    }
}
