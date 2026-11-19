import Foundation

@objcMembers final class iTermGitWorktreeRemover: NSObject {
    private let executor: iTermGitWorktreeCommandExecuting
    // All instances share a queue so two windows cannot delete the same checkout concurrently.
    private static let queue = DispatchQueue(label: "com.iterm2.git-worktree-remover", qos: .utility)

    @nonobjc init(executor: iTermGitWorktreeCommandExecuting) {
        self.executor = executor
    }

    func removeWorktree(_ worktree: iTermGitWorktree, fromRepository repository: iTermGitRepositorySnapshot,
                        deleteBranch: Bool, force: Bool, completion: @escaping (Bool, NSError?) -> Void) {
        Self.queue.async {
            var removed = false
            var failure: NSError?
            do {
                guard !worktree.isMain, !worktree.locked, worktree.available,
                      repository.worktrees.contains(where: { $0.identifier == worktree.identifier && !$0.isMain }),
                      !deleteBranch || worktree.branch != nil else { throw Self.protectedWorktreeError() }
                // Validate again after the confirmation sheet: it may have been open
                // while another terminal switched branches, committed, or locked the checkout.
                var listing = try self.command(["worktree", "list", "--porcelain", "-z"], repository: repository, timeout: 5)
                let nul = listing.status != 129
                if !nul {
                    listing = try self.command(["worktree", "list", "--porcelain"], repository: repository, timeout: 5)
                }
                guard listing.status == 0 else { throw Self.commandError(listing) }
                let records = try iTermGitWorktreePorcelainParser.parse(listing.output, nulDelimited: nul)
                guard let current = records.first(where: {
                    iTermGitWorktreeScanner.normalizedPath($0.path, relativeTo: repository.commonDirectory) == worktree.rootDirectory
                }), !current.isMain, !current.bare, !current.locked else { throw Self.protectedWorktreeError() }
                let expectedBranch = worktree.branch.map { "refs/heads/" + $0 }
                guard current.branch == expectedBranch, current.head == worktree.head else { throw Self.changedWorktreeError() }

                var arguments = ["worktree", "remove"]
                if force { arguments.append("--force") }
                arguments += ["--", worktree.rootDirectory]
                let removal = try self.command(arguments, repository: repository, timeout: 30)
                guard removal.status == 0 else { throw Self.commandError(removal) }
                removed = true
                if deleteBranch, let branch = worktree.branch {
                    // Recheck the branch tip before requesting its deletion.
                    let tip = try self.command(["rev-parse", "--verify", "refs/heads/" + branch], repository: repository, timeout: 5)
                    guard tip.status == 0, tip.output == Data((worktree.head + "\n").utf8) else { throw Self.changedWorktreeError() }
                    let deletion = try self.command(["branch", force ? "-D" : "-d", "--", branch], repository: repository, timeout: 5)
                    guard deletion.status == 0 else { throw Self.commandError(deletion) }
                }
            } catch {
                let underlying = error as NSError
                let message: String
                if removed {
                    message = String(localized: "GitWorktrees.BranchDeleteFailed",
                        defaultValue: "The worktree directory was deleted, but branch deletion could not be confirmed. \(underlying.localizedDescription)",
                        comment: "Partial deletion error; placeholder is the underlying Git error")
                } else {
                    message = underlying.localizedDescription
                }
                failure = NSError(domain: "iTermGitWorktreeRemover", code: underlying.code,
                                  userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: underlying])
            }
            DispatchQueue.main.async { completion(removed, failure) }
        }
    }

    @nonobjc private func command(_ arguments: [String], repository: iTermGitRepositorySnapshot,
                                 timeout: TimeInterval) throws -> iTermGitWorktreeCommandResult {
        let result = executor.run(arguments: ["--git-dir", repository.commonDirectory] + arguments,
                                  directory: repository.commonDirectory, timeout: timeout)
        if result.timedOut {
            throw NSError(domain: "iTermGitWorktreeRemover", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "GitWorktrees.DeleteTimeout",
                    defaultValue: "Git worktree deletion timed out. Refresh the list to check its current state.",
                    comment: "Error when a Git worktree deletion command times out")])
        }
        if result.truncated {
            throw NSError(domain: "iTermGitWorktreeRemover", code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "GitWorktrees.DeleteOutputTooLarge",
                    defaultValue: "Git returned too much output. Refresh the worktree list to check its current state.",
                    comment: "Error when a Git deletion command exceeds its output limit")])
        }
        return result
    }

    private static func protectedWorktreeError() -> NSError {
        NSError(domain: "iTermGitWorktreeRemover", code: 4,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "GitWorktrees.DeleteProtected",
                defaultValue: "This worktree cannot be deleted. Main, locked, and unavailable worktrees are protected. Refresh the list and try again.",
                comment: "Error when a worktree is not eligible for deletion")])
    }

    private static func changedWorktreeError() -> NSError {
        NSError(domain: "iTermGitWorktreeRemover", code: 5,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "GitWorktrees.DeleteChanged",
                defaultValue: "The worktree’s branch or commit changed. Refresh the list and confirm the deletion again.",
                comment: "Error when a worktree changes after the user opens its deletion confirmation")])
    }

    private static func commandError(_ result: iTermGitWorktreeCommandResult) -> NSError {
        let details = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(localized: "GitWorktrees.DeleteRejected",
            defaultValue: "Git could not complete the deletion. To discard uncommitted changes or delete an unmerged branch, select Force Delete in the confirmation dialog.",
            comment: "Error when Git rejects an ordinary worktree or branch deletion")
        return NSError(domain: "iTermGitWorktreeRemover", code: 1,
                       userInfo: ["GitExitStatus": result.status,
                                  NSLocalizedDescriptionKey: message + (details.isEmpty ? "" : "\n\n" + details)])
    }
}
