import Foundation
import RouteCore
import Darwin
import CryptoKit

struct SavedProfile: Codable {
    var version = 1
    var countryEnabled = true
    var rules: [RouteRule] = []
    var lastAppliedCount = 0
    var hasApplied = false
    var events: [ActivityEvent] = []
}

/// Each app instance saves against the exact snapshot it loaded. The stable
/// lock serializes comparison and replacement across processes; atomic writes
/// alone cannot prevent a stale instance from replacing another one's rules.
struct ProfileStorage {
    struct Revision: Equatable, Sendable {
        fileprivate var digest: SHA256.Digest?
        static let missing = Revision(digest: nil)
        fileprivate init(data: Data?) { digest = data.map { SHA256.hash(data: $0) } }
        private init(digest: SHA256.Digest?) { self.digest = digest }
    }

    struct Snapshot {
        var profile: SavedProfile?
        var revision: Revision
    }

    enum StorageError: LocalizedError, Equatable {
        case changed, busy, unsafeLock, unsafeProfile

        var errorDescription: String? {
            switch self {
            case .changed: return "配置已在另一实例或外部程序中更新，未覆盖磁盘上的版本。"
            case .busy: return "另一实例正在保存配置，本次未写入。"
            case .unsafeLock: return "配置锁不是当前用户独占的安全普通文件，未写入配置。"
            case .unsafeProfile: return "配置文件不是当前用户独占的普通文件，未读取或覆盖。"
            }
        }
    }

    let location: URL
    private let writingOptions: Data.WritingOptions

    /// Isolated tests may select ordinary atomic writes when the host's data
    /// protection key is unavailable. Production always keeps file protection.
    init(directory: URL = ProfileStorage.directory,
         writingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]) {
        location = directory
        self.writingOptions = writingOptions.union(.atomic)
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteWeaver", isDirectory: true)
    }
    static func prepareDirectory(at directory: URL = ProfileStorage.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure("配置目录不是安全的普通目录。") }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid() else { throw AppFailure("配置目录所有者不匹配。") }
        guard chmod(directory.path, 0o700) == 0 else { throw AppFailure("无法保护配置目录权限。") }
    }
    func load() throws -> Snapshot {
        try Self.prepareDirectory(at: location)
        let data = try readData()
        let profile = try data.map { try JSONDecoder().decode(SavedProfile.self, from: $0) }
        if let profile {
            guard profile.version == 1, profile.rules.count <= 20000 else { throw AppFailure("配置版本或规则数量不受支持。") }
        }
        return Snapshot(profile: profile, revision: Revision(data: data))
    }

    @discardableResult
    func save(_ profile: SavedProfile, replacing expected: Revision) throws -> Revision {
        try Self.prepareDirectory(at: location)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profile)
        return try withSaveLock {
            guard Revision(data: try readData()) == expected else { throw StorageError.changed }
            let file = location.appendingPathComponent("profile.json")
            try data.write(to: file, options: writingOptions)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return Revision(data: data)
        }
    }

    private func readData() throws -> Data? {
        let file = location.appendingPathComponent("profile.json")
        var status = stat()
        guard lstat(file.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1 else {
            throw StorageError.unsafeProfile
        }
        return try Data(contentsOf: file)
    }

    private func withSaveLock<T>(_ operation: () throws -> T) throws -> T {
        let file = location.appendingPathComponent(".profile.lock")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError.unsafeLock }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw StorageError.unsafeLock }
        // Never wait indefinitely for another GUI while running on its main actor.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw StorageError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        var current = stat()
        guard lstat(file.path, &current) == 0, current.st_dev == status.st_dev,
              current.st_ino == status.st_ino else { throw StorageError.unsafeLock }
        // Keep this inode between saves. Unlinking it would let another process
        // acquire a new lock while an existing descriptor still holds the old one.
        return try operation()
    }
}
