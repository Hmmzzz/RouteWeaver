import Foundation
import Darwin

// A disposable unprivileged executable using the production identity checker.
// The driver replaces only this fixture's path after the process has started.
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(2) }
let mode = arguments[1], candidate = arguments[2]
do {
    let captured = mode == "replace-before-capture" ? nil : try SignedCodeIdentity.runningHash()
    print("READY")
    fflush(stdout)
    guard readLine() == "CONTINUE" else { exit(2) }
    do {
        let pinned = try captured ?? SignedCodeIdentity.runningHash()
        try SignedCodeIdentity.validateExecutable(path: candidate, expectedHash: pinned)
        guard mode == "unchanged" else {
            fputs("Replacement was incorrectly accepted\n", stderr)
            exit(1)
        }
        print("ACCEPTED")
    } catch {
        guard mode != "unchanged" else { throw error }
        print("REJECTED")
    }
} catch {
    fputs("Identity fixture failed: \(error)\n", stderr)
    exit(1)
}
