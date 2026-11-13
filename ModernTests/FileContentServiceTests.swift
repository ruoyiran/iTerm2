import Foundation
import XCTest
@testable import iTerm2SharedARC

final class FileContentServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func git(_ arguments: [String]) throws {
        XCTAssertEqual(try fileBrowserGit(arguments, root: root.path, timeout: 10).0, 0)
    }
    private func initializeGit() throws {
        try git(["init", "-q"]); try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
    }

    func testHistoricalDiffSurvivesRemovalOfItsParentDirectory() throws {
        try initializeGit()
        let directory = root.appendingPathComponent("removed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("old.txt")
        try Data("historical\n".utf8).write(to: path)
        try git(["add", "."]); try git(["commit", "-qm", "first"])
        try FileManager.default.removeItem(at: directory)
        try git(["add", "-u"])
        let service = try FileGitContentService(rootDirectory: root.path)
        XCTAssertEqual(try service.diff(path.path, source: "head")["originalContent"] as? String, "historical\n")
        XCTAssertEqual(try service.diff(path.path, source: "staged")["modifiedContent"] as? String, "")
        XCTAssertEqual(try service.diff(path.path, source: "commit", commit: "HEAD")["modifiedContent"] as? String, "historical\n")
    }

    func testNestedGitOwnerFiltersAndRebasesRepositoryPaths() throws {
        try initializeGit()
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: directory.appendingPathComponent("inside.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        try git(["add", "."])
        let service = try FileGitContentService(rootDirectory: directory.path)
        XCTAssertEqual(try service.status().compactMap { $0["path"] as? String }, ["inside.txt"])
        XCTAssertEqual(try service.changes(source: "staged").compactMap { $0["path"] as? String }, ["inside.txt"])
        XCTAssertEqual(try service.diff(directory.appendingPathComponent("inside.txt").path, source: "head")["modifiedContent"] as? String, "inside")
        XCTAssertThrowsError(try service.diff(root.appendingPathComponent("outside.txt").path, source: "head"))
    }

    func testRangeReadsReturnExactBytesAndRejectOversizedWindows() throws {
        let path = root.appendingPathComponent("sample.txt")
        try Data("a😀\r\nz".utf8).write(to: path)
        let service = try FileContentService(rootDirectory: root.path)
        let result = try service.readRange(path.path, position: 1, length: 4)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(result["data"] as? String)), Data("😀".utf8))
        XCTAssertEqual(result["size"] as? Int64, 8)
        let end = try service.readRange(path.path, position: 7, length: 4)
        XCTAssertEqual(end["byteLength"] as? Int, 1)
        XCTAssertEqual(try service.readRange(path.path, position: 8, length: 4)["byteLength"] as? Int, 0)
        XCTAssertThrowsError(try service.readRange(path.path, position: -1, length: 4))
        XCTAssertThrowsError(try service.readRange(path.path, position: 0, length: 262145))
    }

    func testReadsRejectEscapesAndReplacementOfTheRoot() throws {
        let path = root.appendingPathComponent("sample.txt")
        try Data("private".utf8).write(to: path)
        let service = try FileContentService(rootDirectory: root.path)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try service.readRange(link.path, position: 0, length: 8))
        XCTAssertThrowsError(try service.readRange(root.path + "/../outside", position: 0, length: 8))
        let displaced = root.appendingPathExtension("old")
        try FileManager.default.moveItem(at: root, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: path)
        XCTAssertThrowsError(try service.readRange(path.path, position: 0, length: 8))
    }

    func testGitDiffSeparatesIndexFromWorkingBufferAndRecognizesRenames() throws {
        func git(_ arguments: [String]) throws {
            let result = try fileBrowserGit(arguments, root: root.path, timeout: 10)
            XCTAssertEqual(result.0, 0)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        let path = root.appendingPathComponent("a.txt")
        try Data("base\n".utf8).write(to: path)
        try git(["add", "--", "a.txt"])
        try git(["commit", "-qm", "base"])
        try Data("index\n".utf8).write(to: path)
        try git(["add", "--", "a.txt"])
        try Data("working\n".utf8).write(to: path)
        let service = try FileGitContentService(rootDirectory: root.path)
        let staged = try service.diff(path.path, source: "staged")
        XCTAssertEqual(staged["originalContent"] as? String, "base\n")
        XCTAssertEqual(staged["modifiedContent"] as? String, "index\n")
        let unstaged = try service.diff(path.path, source: "unstaged")
        XCTAssertEqual(unstaged["originalContent"] as? String, "index\n")
        XCTAssertEqual(unstaged["modifiedContent"] as? String, "working\n")
        XCTAssertEqual(Set(try service.status().compactMap { $0["area"] as? String }), ["staged", "unstaged"])
        try git(["reset", "--hard", "-q", "HEAD"])
        try git(["mv", "--", "a.txt", "renamed.txt"])
        let renamed = try service.diff(root.appendingPathComponent("renamed.txt").path, source: "staged")
        XCTAssertEqual(renamed["originalContent"] as? String, "base\n")
        XCTAssertEqual(renamed["modifiedContent"] as? String, "base\n")
        XCTAssertEqual(try service.changes(source: "staged").first?["oldPath"] as? String, "a.txt")
        XCTAssertThrowsError(try service.diff(path.path, source: "branch", baseRef: "--output=/tmp/unsafe"))
    }
    func testUnbornHeadIncludesStagedFilesInCombinedChanges() throws {
        XCTAssertEqual(try fileBrowserGit(["init", "-q"], root: root.path).0, 0)
        let path = root.appendingPathComponent("first.txt")
        try Data("new\n".utf8).write(to: path)
        XCTAssertEqual(try fileBrowserGit(["add", "--", "first.txt"], root: root.path).0, 0)
        let service = try FileGitContentService(rootDirectory: root.path)
        XCTAssertEqual(try service.changes(source: "head").first?["path"] as? String, "first.txt")
        XCTAssertEqual(try service.diff(path.path, source: "head")["originalContent"] as? String, "")
        XCTAssertEqual(try service.diff(path.path, source: "head")["modifiedContent"] as? String, "new\n")
    }
}
