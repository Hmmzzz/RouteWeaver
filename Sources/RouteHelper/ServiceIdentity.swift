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
        var code: SecStaticCode?
        try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess && code != nil, "无法读取程序签名")
        // Validate the executable itself, avoiding mutable FinderInfo on the enclosing bundle.
        try require(SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess, "程序签名已损坏")
        return try hash(code!)
    }
    private static func hash(_ code: SecStaticCode) throws -> Data {
        var info: CFDictionary?
        try require(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, "无法读取签名标识")
        guard let dictionary = info as? [String: Any], let value = dictionary[kSecCodeInfoUnique as String] as? Data, !value.isEmpty else { throw HelperError("程序缺少代码签名摘要") }
        return value
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
        try require(SecCodeCheckValidity(guest!, [], nil) == errSecSuccess, "客户端代码签名无效")
        var staticCode: SecStaticCode?
        try require(SecCodeCopyStaticCode(guest!, [], &staticCode) == errSecSuccess && staticCode != nil, "客户端签名标识不可用")
        let peerHash = try hash(staticCode!)
        try require(peerHash == configuration.appCodeHash, "客户端版本与授权版本不匹配，请重新安装后台服务")
    }
}
