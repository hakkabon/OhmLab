import Foundation

/// Confines manifest- and backend-provided relative paths to a project root.
/// Project files are external input, so callers must not append their paths to
/// a root URL without validating them first.
enum ProjectPath {
    static func resolve(_ relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty else {
            throw ProjectBundleError.corruptManifest("an empty project path")
        }

        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw ProjectBundleError.corruptManifest("absolute project path: \(relativePath)")
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectBundleError.corruptManifest("unsafe project path: \(relativePath)")
        }

        // Build the candidate from the canonical root so a root reached through
        // a symlink (for example `/var` -> `/private/var`) does not make every
        // valid path look like it escapes. Then resolve the deepest existing
        // ancestor, which catches symlinked subfolders that point outside the
        // bundle even when the final file does not exist yet.
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(normalized).standardizedFileURL
        guard isInside(resolvedPath(candidate), root: canonicalRoot) else {
            throw ProjectBundleError.corruptManifest("project path escapes its bundle: \(relativePath)")
        }
        return candidate
    }

    /// Resolves symlinks along the existing prefix of `url` and re-appends the
    /// components that do not exist yet.
    private static func resolvedPath(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existing = url
        var missing: [String] = []
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
