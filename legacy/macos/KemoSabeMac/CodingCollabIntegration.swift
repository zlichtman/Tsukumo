import Foundation

/// The Git side of collaboration: checkpoints of a task's worktree, merging finished subtasks into
/// an integration branch in dependency order, conflict detection, the project's test command, and
/// accepting the integrated result with the same reviewed-tree rules as a single task's Accept.
/// Nothing here resets, forces, or deletes a branch or worktree.
enum CodingIntegration {
    enum MergeOutcome: Equatable {
        /// Merged; the new head.
        case merged(String)
        /// Already part of the branch (for example, a dependency another merge brought in).
        case unchanged
        /// These files conflict. The merge was aborted unless it was asked to stay open.
        case conflict([String])
    }

    @discardableResult static func git(_ arguments: [String], at directory: URL) async throws -> String {
        try await CodingCommand.git(arguments, at: directory)
    }

    /// Commits the worktree's files exactly as they are (the same snapshot tree a review uses)
    /// onto its branch, so another worktree can start from them or an integration can merge
    /// them. A merge in progress there keeps its second parent. Returns the branch's head, which
    /// is unchanged when there was nothing new.
    static func checkpoint(_ directory: URL, message: String) async throws -> String {
        let head = try await git(["rev-parse", "HEAD"], at: directory)
        let merging = try? await git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], at: directory)
        let tree = try await CodingWorkspaceStore.snapshotTree(at: directory)
        if merging == nil, try await git(["rev-parse", head + "^{tree}"], at: directory) == tree { return head }
        var arguments = ["commit-tree", tree, "-p", head]
        if let merging { arguments += ["-p", merging] }
        let commit = try await git(arguments + ["-m", message], at: directory)
        let branch = try await git(["symbolic-ref", "-q", "HEAD"], at: directory)
        // Compare-and-swap: only moves the branch if nothing else moved it meanwhile.
        try await git(["update-ref", "-m", "Tsukumo: checkpoint", branch, commit, head], at: directory)
        // The index follows the branch; the files are already what was committed.
        try await git(["read-tree", commit], at: directory)
        if merging != nil { try? await git(["merge", "--quit"], at: directory) }
        return commit
    }

    /// Lines Git leaves in a file it couldn't merge.
    static func conflictMarkers(in directory: URL, paths: [String]) -> [String] {
        paths.filter { path in
            guard CollabPaths.valid(path), let text = try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "=======" }
        }
    }

    /// A new worktree on a new branch, starting at `base`, outside the project.
    static func addWorktree(project root: URL, base: String, directory: URL, branch: String) async throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(["worktree", "add", "-b", branch, directory.path, base], at: root)
    }

    /// Merges a commit into the worktree's branch. On a conflict it lists the conflicted files and
    /// aborts, leaving the branch as it was, unless `keepConflicts` asks to leave the merge open
    /// for someone to resolve.
    static func merge(_ commit: String, into directory: URL, message: String, keepConflicts: Bool = false) async throws -> MergeOutcome {
        let ancestor = try await CodingCommand.run("/usr/bin/git", ["merge-base", "--is-ancestor", commit, "HEAD"], at: directory)
        if ancestor.code == 0 { return .unchanged }
        let result = try await CodingCommand.run("/usr/bin/git", ["-c", "core.quotepath=false", "merge", "--no-ff", "--no-edit", "-m", message, commit], at: directory, timeout: 120, environment: ["GIT_MERGE_AUTOEDIT": "no"])
        if result.code == 0 { return .merged(try await git(["rev-parse", "HEAD"], at: directory)) }
        let conflicted = (try? await git(["diff", "--name-only", "--diff-filter=U", "-z"], at: directory))?.split(separator: "\0").map(String.init) ?? []
        guard !conflicted.isEmpty else {
            try? await git(["merge", "--abort"], at: directory)
            throw CodingFailure(result.output.isEmpty ? "Git couldn't merge \(commit.prefix(12))." : result.output)
        }
        if !keepConflicts { try await git(["merge", "--abort"], at: directory) }
        return .conflict(conflicted.sorted())
    }

    /// One commit holding several results, for a subtask that depends on more than one: each is
    /// merged in turn without a worktree (`merge-tree`). A result that conflicts is left out and
    /// its files are returned, so the subtask starts anyway and integration settles the conflict.
    static func combine(_ commits: [String], at root: URL) async throws -> (commit: String, conflicts: [String]) {
        guard var head = commits.first else { throw CodingFailure("Nothing to combine.") }
        var conflicts: [String] = []
        for commit in commits.dropFirst() {
            if try await CodingCommand.run("/usr/bin/git", ["merge-base", "--is-ancestor", commit, head], at: root).code == 0 { continue }
            if try await CodingCommand.run("/usr/bin/git", ["merge-base", "--is-ancestor", head, commit], at: root).code == 0 { head = commit; continue }
            let result = try await CodingCommand.run("/usr/bin/git", ["-c", "core.quotepath=false", "merge-tree", "--write-tree", "--name-only", "--no-messages", head, commit], at: root)
            let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if result.code == 0, let tree = lines.first, !tree.isEmpty {
                head = try await git(["commit-tree", tree, "-p", head, "-p", commit, "-m", "Tsukumo: combine results"], at: root)
            } else if result.code == 1 {
                conflicts += lines.dropFirst().filter { !$0.isEmpty }
            } else { throw CodingFailure(result.output.isEmpty ? "Git couldn't combine the results." : result.output) }
        }
        return (head, conflicts)
    }

    /// What a commit changed since `base`, file by file.
    static func changedFiles(from base: String, to commit: String, at directory: URL) async throws -> [OrchestratorHandoff.File] {
        OrchestratorHandoff.files(numstat: try await git(["diff", "--numstat", "-z", "--no-renames", base, commit, "--"], at: directory))
    }

    /// The project's own test command, found from its files: a Makefile's `test` target, then the
    /// usual one for Swift packages, Node, Rust, Go, and Python. Nil when there's nothing clear.
    static func detectTestCommand(at root: URL) -> String? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        if let makefile = read("Makefile") ?? read("makefile"), makefile.split(separator: "\n").contains(where: { $0.hasPrefix("test:") }) { return "make test" }
        if exists("Package.swift") { return "swift test" }
        if let data = read("package.json")?.data(using: .utf8),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = package["scripts"] as? [String: Any], let test = scripts["test"] as? String,
           !test.contains("no test specified") {
            if exists("pnpm-lock.yaml") { return "pnpm test" }
            if exists("yarn.lock") { return "yarn test" }
            if exists("bun.lockb") || exists("bun.lock") { return "bun run test" }
            return "npm test"
        }
        if exists("Cargo.toml") { return "cargo test" }
        if exists("go.mod") { return "go test ./..." }
        if exists("pytest.ini") || exists("tox.ini") || read("pyproject.toml")?.contains("pytest") == true || read("setup.cfg")?.contains("[tool:pytest]") == true { return "python3 -m pytest" }
        return nil
    }

    /// Runs a test command in the folder. The result vouches for a tree only if the files were
    /// the same before and after, exactly as a task's checks do.
    static func runTests(_ command: String, in directory: URL, timeout: TimeInterval = 900) async -> OrchestratorTestResult {
        let before = try? await CodingWorkspaceStore.snapshotTree(at: directory)
        do {
            let result = try await CodingCommand.run("/bin/zsh", ["-l", "-c", command], at: directory, timeout: timeout)
            let after = try? await CodingWorkspaceStore.snapshotTree(at: directory)
            return .init(command: command, passed: result.code == 0, exitCode: Int(result.code), output: String(result.output.suffix(12_000)), tree: before != nil && before == after ? before : nil, date: Date())
        } catch {
            return .init(command: command, passed: false, exitCode: nil, output: error.localizedDescription, tree: nil, date: Date())
        }
    }

    /// A review of the integration branch against the base: the snapshot tree Accept will commit.
    static func review(run: UUID, directory: URL, base: String) async throws -> CodingReview {
        let head = try await git(["rev-parse", "HEAD"], at: directory)
        let tree = try await CodingWorkspaceStore.snapshotTree(at: directory)
        let diff = try await git(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base, tree, "--"], at: directory)
        return .init(taskID: run, base: base, head: head, tree: tree, diff: diff.isEmpty ? "No changes." : diff)
    }

    /// Accepts the reviewed integration into the project's base branch, with a single task's
    /// Accept rules: the branch and files must still be what was reviewed, the project must be on
    /// its base branch with no uncommitted changes, the reviewed tree itself is committed (never
    /// the files on disk), and the project only fast-forwards. Returns the accepted commit.
    static func accept(_ review: CodingReview, integration directory: URL, branch: String, project root: URL, baseBranch: String, title: String) async throws -> String {
        guard try await git(["symbolic-ref", "--short", "HEAD"], at: directory) == branch else { throw CodingFailure("The integration branch changed. Integrate again before accepting.") }
        guard try await git(["rev-parse", "HEAD"], at: directory) == review.head else { throw CodingFailure("The integration moved since review. Review it again before accepting.") }
        guard try await CodingWorkspaceStore.snapshotTree(at: directory) == review.tree else { throw CodingFailure("Files changed since review. Review again before accepting.") }
        guard try await git(["symbolic-ref", "--short", "HEAD"], at: root) == baseBranch else { throw CodingFailure("The project's branch changed. Switch back to \(baseBranch) before accepting.") }
        guard try await git(["status", "--porcelain"], at: root).isEmpty else { throw CodingFailure("Save or commit the project's existing changes before accepting.") }
        var commit = review.head
        if try await git(["rev-parse", review.head + "^{tree}"], at: directory) != review.tree {
            commit = try await git(["commit-tree", review.tree, "-p", review.head, "-m", "Tsukumo: " + title], at: directory)
            try await git(["update-ref", "-m", "Tsukumo: accept reviewed tree", "refs/heads/" + branch, commit, review.head], at: directory)
            try await git(["read-tree", commit], at: directory)
        }
        do { try await git(["merge", "--ff-only", commit], at: root) }
        catch { throw CodingFailure("\(baseBranch) moved since the integration started, so it can't fast-forward. Integrate again on top of it.") }
        return commit
    }
}

struct OrchestratorTestResult: Codable, Equatable, Sendable {
    var command: String
    var passed: Bool
    var exitCode: Int?
    var output: String
    /// The integration tree the tests ran on, when the files didn't change while they ran.
    var tree: String?
    var date: Date
}
