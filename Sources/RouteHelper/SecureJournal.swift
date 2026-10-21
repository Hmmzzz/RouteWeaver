import Foundation
import Darwin

/// The root-only directory is opened one component at a time. No path lookup
/// after this point can be redirected through a user-controlled symlink.
protocol JournalStoring {
    func load() throws -> Journal
    func save(_ journal: Journal) throws
}

final class SecureJournal: JournalStoring {
    private var directory: Int32 = -1
    private var lock: Int32 = -1
    init() throws {
        let parent = try secureSystemDirectory()
        try require(parent >= 0, "无法打开系统状态目录")
        defer { if parent >= 0 { close(parent) } }
        var info = stat()
        try require(fstat(parent, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0, "系统状态目录权限不安全")
        let name = "com.routeweaver.routes"
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw HelperError("无法创建恢复目录") }
        directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(directory >= 0, "恢复目录不是安全目录")
        try require(fstat(directory, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o077 == 0, "恢复目录必须由 root 私有持有")
        lock = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(lock >= 0, "无法创建路由操作锁")
        try require(fstat(lock, &info) == 0 && info.st_uid == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_mode & 0o077 == 0, "操作锁权限不安全")
        try require(flock(lock, LOCK_EX | LOCK_NB) == 0, "另一个路由操作正在进行，请稍后重试")
    }
    deinit { if lock >= 0 { close(lock) }; if directory >= 0 { close(directory) } }
    func load() throws -> Journal {
        let fd = openat(directory, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return Journal() }
        try require(fd >= 0, "无法安全读取恢复日志")
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_mode & 0o077 == 0, "恢复日志权限不安全")
        try require(info.st_size >= 0 && info.st_size <= 8 * 1024 * 1024, "恢复日志长度异常")
        let data = try readAll(fd, maximum: 8 * 1024 * 1024)
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        try require((journal.version == 1 || journal.version == 2) && journal.records.count <= 20_000, "不支持的恢复日志格式")
        return journal
    }
    func save(_ journal: Journal) throws {
        try require((journal.version == 1 || journal.version == 2) && journal.records.count <= 20_000, "恢复日志条目超限或版本无效")
        let data = try JSONEncoder().encode(journal)
        try require(data.count <= 8 * 1024 * 1024, "恢复日志长度超限")
        let name = "journal-\(UUID().uuidString).tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "无法创建恢复日志")
        defer { close(fd); unlinkat(directory, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "恢复日志写入失败；已停止修改路由")
                offset += count
            }
        }
        try require(fsync(fd) == 0, "恢复日志同步失败；已停止修改路由")
        try require(renameat(directory, name, directory, "journal.json") == 0, "恢复日志提交失败")
        try require(fsync(directory) == 0, "恢复目录同步失败")
    }
}
func readAll(_ fd: Int32, maximum: Int) throws -> Data {
    var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        try require(count >= 0, "读取失败")
        if count == 0 { return result }
        try require(result.count + count <= maximum, "输入超过允许大小")
        result.append(contentsOf: buffer.prefix(count))
    }
}

private func secureSystemDirectory() throws -> Int32 {
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "无法打开系统根目录")
    do {
        for component in ["private", "var", "db"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(next >= 0, "系统目录链不安全")
            close(fd); fd = next
            var info = stat()
            try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0, "系统目录链必须由 root 控制")
        }
        return fd
    } catch { close(fd); throw error }
}
