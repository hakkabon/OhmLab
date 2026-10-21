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

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(normalized).standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isInside(resolvedParent, root: canonicalRoot),
              isInside(resolvedCandidate, root: canonicalRoot) else {
            throw ProjectBundleError.corruptManifest("project path escapes its bundle: \(relativePath)")
        }
        return candidate
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
