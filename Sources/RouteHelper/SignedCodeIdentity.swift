import Foundation
import Security

/// Identity is established from a live code object, never from argv[0]. Keep
/// the captured value across staging so replacing a user-owned source cannot
/// change which executable the privileged installer is allowed to install.
enum SignedCodeIdentity {
    static func runningHash() throws -> Data {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw IdentityError("无法读取安装器进程身份")
        }
        return try dynamicHash(code)
    }

    static func dynamicHash(_ code: SecCode) throws -> Data {
        var diskCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &diskCode) == errSecSuccess, let diskCode else {
            throw IdentityError("无法读取进程签名标识")
        }
        let value = try hash(diskCode)
        let hex = value.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              // CopyStaticCode alone is not a secure binding. Dynamic validation
              // checks the disk identity against the actual running process and
              // rejects a replacement even when it has a valid ad-hoc signature.
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw IdentityError("运行进程与磁盘程序签名不匹配")
        }
        return value
    }

    static func staticHash(path: String) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw IdentityError("程序签名无效")
        }
        return try hash(code)
    }

    @discardableResult
    static func validateExecutable(path: String, expectedHash: Data) throws -> Data {
        let actual = try staticHash(path: path)
        guard !expectedHash.isEmpty, actual == expectedHash else {
            throw IdentityError("待安装程序与已授权安装器不匹配")
        }
        return actual
    }

    private static func hash(_ code: SecStaticCode) throws -> Data {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let value = dictionary[kSecCodeInfoUnique as String] as? Data, !value.isEmpty else {
            throw IdentityError("程序缺少代码签名摘要")
        }
        return value
    }

    private struct IdentityError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
