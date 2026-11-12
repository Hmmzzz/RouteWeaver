import Foundation
import Darwin
import Security
import RouteIPC

struct ServiceConfiguration: Codable {
    var version = 1
    let ownerUID: uid_t
    let appCodeHash: Data
    let helperCodeHash: Data
    static func load() throws -> ServiceConfiguration {
        let fd = open(ServicePaths.configuration, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "服务身份配置不存在")
        defer { close(fd) }
        var st = stat()
        try require(fstat(fd, &st) == 0 && st.st_uid == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_mode & 0o777 == 0o600 && st.st_nlink == 1 && st.st_size > 0 && st.st_size <= 8192, "服务身份配置权限无效")
        var bytes = Data(count: Int(st.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        try require(count == bytes.count, "无法读取服务身份配置")
        let result = try JSONDecoder().decode(Self.self, from: bytes)
        try require(result.version == 1 && result.ownerUID >= 500 && !result.appCodeHash.isEmpty && !result.helperCodeHash.isEmpty, "服务身份配置无效")
        return result
    }
}

enum ServiceIdentity {
    static func staticHash(path: String) throws -> Data {
        try SignedCodeIdentity.staticHash(path: path)
    }
    static func authenticate(fd: Int32, configuration: ServiceConfiguration) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        try require(getpeereid(fd, &uid, &gid) == 0 && uid == configuration.ownerUID, "客户端用户身份不匹配")
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        try require(getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 && length == MemoryLayout<audit_token_t>.size, "无法核验客户端进程身份")
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: audit] as CFDictionary
        try require(SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess && guest != nil, "无法读取客户端动态签名")
        let peerHash = try SignedCodeIdentity.dynamicHash(guest!)
        try require(peerHash == configuration.appCodeHash, "客户端版本与授权版本不匹配，请重新安装后台服务")
    }
}
