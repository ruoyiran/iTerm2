import Foundation
import Darwin
import XCTest
#if !GIT_WORKTREE_REMOVER_STANDALONE
@testable import iTerm2SharedARC
#endif

final class GitWorktreeRemoverTests: XCTestCase {
    func testDirectoryRemovalKeepsBranchAndRefreshesGitRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let snapshot = try scan(fixture)
        let worktree = try XCTUnwrap(snapshot.worktrees.first { !$0.isMain })
        let result = remove(fixture, worktree: worktree, repository: snapshot, deleteBranch: false)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
        XCTAssertEqual(try scan(fixture).worktrees.map(\.rootDirectory), [fixture.root])
    }

    func testCombinedRemovalDeletesDirectoryAndBranchWithSpecialPathCharacters() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let snapshot = try scan(fixture)
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: true)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertNotEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root))
    }

    func testDirtyTrackedAndUntrackedFilesPreventBothDeletions() throws {
        for tracked in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let snapshot = try scan(fixture)
            let filename = tracked ? "tracked.txt" : "untracked.txt"
            let path = fixture.linked + "/" + filename
            try Data("local changes".utf8).write(to: URL(fileURLWithPath: path))
            let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: true)
            XCTAssertFalse(result.removed)
            XCTAssertNotNil(result.error)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "local changes")
            XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
        }
    }

    func testMainAndNewlyLockedWorktreesCannotBeDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let snapshot = try scan(fixture)
        let main = try XCTUnwrap(snapshot.worktrees.first)
        let mainResult = remove(fixture, worktree: main, repository: snapshot, deleteBranch: true)
        XCTAssertFalse(mainResult.removed)
        XCTAssertNotNil(mainResult.error)
        try fixture.git(["worktree", "lock", fixture.linked])
        let locked = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: true)
        XCTAssertFalse(locked.removed)
        XCTAssertNotNil(locked.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked))
    }

    func testBranchChangedAfterConfirmationPreservesWorktree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let snapshot = try scan(fixture)
        try fixture.git(["-C", fixture.linked, "switch", "-c", "replacement"])
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: true)
        XCTAssertFalse(result.removed)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/replacement"]).status, 0)
    }

    func testUnmergedBranchIsRetainedAndReportsPartialRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.git(["-C", fixture.linked, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "--allow-empty", "-m", "unmerged"])
        let snapshot = try scan(fixture)
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: true)
        XCTAssertTrue(result.removed)
        XCTAssertNotNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
    }

    func testDetachedWorktreeCanBeRemovedWithoutDeletingABranch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.git(["-C", fixture.linked, "switch", "--detach"])
        let snapshot = try scan(fixture)
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot, deleteBranch: false)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
    }

    func testWorktreeFromAnotherRepositoryIsRejected() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanUp(); second.cleanUp() }
        let snapshot = try scan(first)
        let other = try XCTUnwrap(try scan(second).worktrees.last)
        let result = remove(first, worktree: other, repository: snapshot, deleteBranch: true)
        XCTAssertFalse(result.removed)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.linked))
    }

    func testForceRemovalDiscardsDirtyFilesAndDeletesUnmergedBranch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.git(["-C", fixture.linked, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "--allow-empty", "-m", "unmerged"])
        try Data("local changes".utf8).write(to: URL(fileURLWithPath: fixture.linked + "/tracked.txt"))
        try Data("untracked".utf8).write(to: URL(fileURLWithPath: fixture.linked + "/untracked.txt"))
        let snapshot = try scan(fixture)
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot,
                            deleteBranch: true, force: true)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertNotEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
    }

    func testForceDirectoryRemovalKeepsBranch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data("local changes".utf8).write(to: URL(fileURLWithPath: fixture.linked + "/tracked.txt"))
        let snapshot = try scan(fixture)
        let result = remove(fixture, worktree: try XCTUnwrap(snapshot.worktrees.last), repository: snapshot,
                            deleteBranch: false, force: true)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked))
        XCTAssertEqual(fixture.run(["show-ref", "--verify", "refs/heads/feature/test"]).status, 0)
    }

    func testForceStillProtectsMainAndLockedWorktrees() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let snapshot = try scan(fixture)
        try fixture.git(["worktree", "lock", fixture.linked])
        for worktree in snapshot.worktrees {
            let result = remove(fixture, worktree: worktree, repository: snapshot, deleteBranch: true, force: true)
            XCTAssertFalse(result.removed)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.rootDirectory))
        }
    }

    private func scan(_ fixture: Fixture) throws -> iTermGitRepositorySnapshot {
        let done = expectation(description: "scan")
        var snapshot: iTermGitRepositorySnapshot?
        iTermGitWorktreeScanner(executor: fixture.executor).scan(directory: fixture.root) { value, error in
            XCTAssertNil(error)
            snapshot = value
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(snapshot)
    }

    private func remove(_ fixture: Fixture, worktree: iTermGitWorktree, repository: iTermGitRepositorySnapshot,
                        deleteBranch: Bool, force: Bool = false) -> (removed: Bool, error: NSError?) {
        let done = expectation(description: "remove")
        var result: (Bool, NSError?) = (false, nil)
        iTermGitWorktreeRemover(executor: fixture.executor).removeWorktree(worktree, fromRepository: repository,
                                                                         deleteBranch: deleteBranch, force: force) { removed, error in
            XCTAssertTrue(Thread.isMainThread)
            result = (removed, error)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    private final class Fixture {
        let base: String
        let root: String
        let linked: String
        let executor = Executor()

        init() throws {
            guard let temporary = realpath(NSTemporaryDirectory(), nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(temporary) }
            base = String(cString: temporary) + "/git-remover-" + UUID().uuidString
            root = base + "/main"
            linked = base + "/工作 tree\n‘quoted’ $literal"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try git(["init", "-b", "main"])
            try Data("original".utf8).write(to: URL(fileURLWithPath: root + "/tracked.txt"))
            try git(["add", "tracked.txt"])
            try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "initial"])
            try git(["worktree", "add", "-b", "feature/test", linked])
        }

        func run(_ arguments: [String]) -> iTermGitWorktreeCommandResult {
            executor.run(arguments: arguments, directory: root, timeout: 10)
        }

        func git(_ arguments: [String]) throws {
            let result = run(arguments)
            guard result.status == 0 else {
                throw NSError(domain: "GitWorktreeRemoverFixture", code: Int(result.status),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: result.output, as: UTF8.self)])
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(atPath: base) }
    }

    private final class Executor: iTermGitWorktreeCommandExecuting {
        func run(arguments: [String], directory: String, timeout: TimeInterval) -> iTermGitWorktreeCommandResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            // Successful discovery output must stay machine-readable.
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .init(output: Data(), status: -1) }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(output: data, status: process.terminationStatus)
        }
    }
}

#if GIT_WORKTREE_REMOVER_STANDALONE
@main struct GitWorktreeRemoverTestMain {
    static func main() {
        let suite = GitWorktreeRemoverTests.defaultTestSuite
        suite.run()
        exit(suite.testRun!.hasSucceeded ? 0 : 1)
    }
}
#endif
