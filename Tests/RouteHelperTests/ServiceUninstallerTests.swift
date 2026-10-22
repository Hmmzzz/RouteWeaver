import XCTest
import Darwin
@testable import RouteHelper

final class ServiceUninstallerTests: XCTestCase {
    private func fixture(_ body: (URL, UninstallDirectory) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routeweaver-uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try XCTUnwrap(fd >= 0 ? fd : nil)
        let directory = try UninstallDirectory(fd: fd, owner: getuid())
        try body(url, directory)
    }
    private func file(_ url: URL) throws {
        try Data("fixture".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    func testKnownFilesRemovedAndRepeatedRemovalIsIdempotent() throws {
        try fixture { url, directory in
            try file(url.appendingPathComponent("journal.json"))
            try file(url.appendingPathComponent("lock"))
            let names = try directory.auditedEntries { ServiceUninstaller.isStateFile($0, routes: true) }
            XCTAssertEqual(names, ["journal.json", "lock"])
            for name in names { try directory.remove(name); try directory.remove(name) }
            XCTAssertEqual(try directory.entries(), [])
        }
    }
    func testUnknownEntryPreventsDeletionOfRecoveryData() throws {
        try fixture { url, directory in
            try file(url.appendingPathComponent("journal.json"))
            try file(url.appendingPathComponent("do-not-delete"))
            XCTAssertThrowsError(try directory.auditedEntries { ServiceUninstaller.isStateFile($0, routes: true) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("journal.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("do-not-delete").path))
        }
    }
    func testSymlinkAndHardlinkAreRejectedWithoutTouchingTarget() throws {
        try fixture { url, directory in
            let target = url.appendingPathComponent("target")
            try file(target)
            XCTAssertEqual(symlink(target.path, url.appendingPathComponent("journal.json").path), 0)
            XCTAssertThrowsError(try directory.remove("journal.json"))
            XCTAssertEqual(link(target.path, url.appendingPathComponent("lock").path), 0)
            XCTAssertThrowsError(try directory.remove("lock"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }
    func testWritableFilesAndSubdirectoriesAreRejected() throws {
        try fixture { url, directory in
            let path = url.appendingPathComponent("journal.json")
            try file(path); XCTAssertEqual(chmod(path.path, 0o666), 0)
            XCTAssertThrowsError(try directory.remove("journal.json"))
            try FileManager.default.createDirectory(at: url.appendingPathComponent("lock"), withIntermediateDirectories: false)
            XCTAssertThrowsError(try directory.remove("lock"))
        }
    }
    func testManifestAcceptsOnlyOurUUIDTemporaryFiles() {
        let id = UUID().uuidString
        XCTAssertTrue(ServiceUninstaller.isStateFile("journal-\(id).tmp", routes: true))
        XCTAssertTrue(ServiceUninstaller.isStateFile("policy-\(id).tmp", routes: false))
        XCTAssertTrue(ServiceUninstaller.isStateFile("identity.json.\(id)", routes: false))
        XCTAssertFalse(ServiceUninstaller.isStateFile("journal-private.tmp", routes: true))
        XCTAssertFalse(ServiceUninstaller.isStateFile("policy-\(id).tmp", routes: true))
        XCTAssertFalse(ServiceUninstaller.isStateFile("journal-\(id).tmp", routes: false))
    }
    func testPathTraversalAndWrongSocketTypeAreRejected() throws {
        try fixture { url, directory in
            try file(url.appendingPathComponent("socket"))
            XCTAssertThrowsError(try directory.remove("../outside"))
            XCTAssertThrowsError(try directory.remove("socket", socketOwner: getuid()))
        }
    }
    func testChildDirectoryMustBeEmptyAndIdentityMustMatch() throws {
        try fixture { url, parent in
            let childURL = url.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let child = try UninstallDirectory(fd: open(childURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), owner: getuid())
            try file(childURL.appendingPathComponent("unknown"))
            XCTAssertThrowsError(try parent.removeChildDirectory("child", child: child))
            try child.remove("unknown")
            XCTAssertNoThrow(try parent.removeChildDirectory("child", child: child))
            XCTAssertFalse(FileManager.default.fileExists(atPath: childURL.path))
        }
    }
    func testReplacementDirectoryIsNotRemoved() throws {
        try fixture { url, parent in
            let childURL = url.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let child = try UninstallDirectory(fd: open(childURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), owner: getuid())
            try FileManager.default.moveItem(at: childURL, to: url.appendingPathComponent("original"))
            try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertThrowsError(try parent.removeChildDirectory("child", child: child))
            XCTAssertTrue(FileManager.default.fileExists(atPath: childURL.path))
        }
    }
    func testDirectoryLockSerializesWithoutCreatingAFile() throws {
        try fixture { url, first in
            let second = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { close(second) }
            XCTAssertEqual(flock(first.fd, LOCK_EX | LOCK_NB), 0)
            defer { _ = flock(first.fd, LOCK_UN) }
            XCTAssertEqual(flock(second, LOCK_EX | LOCK_NB), -1)
            XCTAssertEqual(errno, EWOULDBLOCK)
            XCTAssertEqual(try first.entries(), [])
        }
    }

}
