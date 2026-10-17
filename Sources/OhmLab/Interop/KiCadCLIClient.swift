// KiCadCLIClient.swift
// Thin wrapper around KiCad's `kicad-cli` for exporting SPICE netlists from
// `.kicad_sch` schematics. macOS only: the CLI ships inside the KiCad app bundle.

#if os(macOS)
import Foundation

public enum KiCadCLIError: LocalizedError {
    case executableNotFound([String])
    case launchFailed(String)
    case conversionFailed(message: String, exitCode: Int32)
    case timedOut(seconds: TimeInterval)
    case missingOutput(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let candidates):
            return "kicad-cli was not found. Looked in: \(candidates.joined(separator: ", "))."
        case .launchFailed(let message):
            return "Could not launch kicad-cli: \(message)"
        case .conversionFailed(let message, let exitCode):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "kicad-cli failed (exit \(exitCode))\(detail.isEmpty ? "." : ": \(detail)")"
        case .timedOut(let seconds):
            return "kicad-cli did not finish within \(Int(seconds))s."
        case .missingOutput(let path):
            return "kicad-cli reported success but produced no netlist at \(path)."
        }
    }
}

/// Locates and runs the KiCad command-line interface.
///
/// The client is deliberately dependency-free: it never assumes KiCad is on
/// `PATH`, because the app-bundle location is the normal case on macOS. All
/// filesystem probing goes through `locate`, so tests can pin an explicit
/// executable without touching the environment.
public enum KiCadCLIClient {
    /// Well-known install locations, checked in order.
    public static let defaultPaths: [String] = [
        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
        "/usr/local/bin/kicad-cli",
        "/opt/homebrew/bin/kicad-cli",
        "/usr/bin/kicad-cli"
    ]

    /// Returns the first usable executable, honoring an explicit override first,
    /// then the well-known locations, then (optionally) `PATH`.
    public static func locate(explicitPath: String? = nil, searchPATH: Bool = true) -> URL? {
        var candidates: [String] = []
        if let explicitPath, !explicitPath.isEmpty {
            candidates.append((explicitPath as NSString).expandingTildeInPath)
        }
        candidates.append(contentsOf: defaultPaths)
        if searchPATH, let pathValue = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                candidates.append((String(directory) as NSString).appendingPathComponent("kicad-cli"))
            }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    public static var isAvailable: Bool { locate() != nil }

    /// The argv passed to `kicad-cli` to export `schematic` to `output`.
    /// Exposed for testing the invocation without running KiCad.
    public static func exportArguments(schematic: URL, output: URL) -> [String] {
        ["sch", "export", "netlist", "--format", "spice",
         "--output", output.path, schematic.path]
    }

    /// Exports a SPICE netlist from a `.kicad_sch` file and returns its text.
    ///
    /// - Parameters:
    ///   - schematic: the source schematic.
    ///   - executable: an explicit `kicad-cli`; discovered automatically when nil.
    ///   - timeout: seconds to wait before terminating the child process.
    public static func exportSpiceNetlist(
        from schematic: URL,
        executable: URL? = nil,
        timeout: TimeInterval = 60
    ) throws -> String {
        guard let cli = executable ?? locate() else {
            throw KiCadCLIError.executableNotFound(defaultPaths)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-\(UUID().uuidString).cir")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = cli
        process.arguments = exportArguments(schematic: schematic, output: output)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw KiCadCLIError.launchFailed(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw KiCadCLIError.timedOut(seconds: timeout)
        }

        let errorText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw KiCadCLIError.conversionFailed(
                message: errorText, exitCode: process.terminationStatus
            )
        }

        guard let data = try? Data(contentsOf: output) else {
            throw KiCadCLIError.missingOutput(output.path)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
