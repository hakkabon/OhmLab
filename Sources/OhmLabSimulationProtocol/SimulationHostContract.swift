import Foundation

/// Foundation-only contracts shared by local, service, and future non-Apple
/// simulation hosts. This target intentionally has no solver or UI dependency.
public enum SimulationHostContract {
    public static let currentVersion = 1
    public static let maximumBatchItems = 256
    public static let mediaType = "application/vnd.ohmlab.simulation+json;version=1"
    public static let requestSchemaID = "urn:ohmlab:schema:portable-simulation-request:1"
    public static let responseSchemaID = "urn:ohmlab:schema:portable-simulation-response:1"
    public static let batchSchemaID = "urn:ohmlab:schema:portable-simulation-batch:1"
    public static let batchResponseSchemaID = "urn:ohmlab:schema:portable-simulation-batch-response:1"
    public static let canonicalEncoding = "json-sorted-keys-utf8"

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Compatibility vocabulary for the process-native Rust host introduced in
/// OhmLab 2.2. The executable is independently built and does not link Swift.
public enum NativeRustPortabilityContract {
    public static let currentVersion = 2
    public static let backendIdentifier = "rust-numeric-core"
    public static let implementationVersion = "rust-numeric-core-0.34.0-native.2"
    public static let rustNumericCoreVersion = "0.34.0"
    public static let supportedAnalyses = [
        "dc-operating-point", "ac-small-signal", "transient", "dc-sweep",
    ]
    public static let supportedFeatures = [
        "circuit-ir-input", "source-waveforms", "initial-conditions",
    ]
}

/// Release contract that closes the portable analysis gap between the
/// Swift-NumericCore adapter and the process-native Rust-NumericCore host.
public enum NumericCoreFeatureCompletionContract {
    public static let currentVersion = 1
    public static let swiftNumericCoreVersion = "1.1.0"
    public static let rustNumericCoreVersion = "0.34.0"
    public static let analyses = [
        "dc-operating-point", "ac-small-signal", "transient", "dc-sweep",
    ]
}

/// Per-host limits may narrow, but never expand, the protocol's global safety
/// ceilings. Timeout is elapsed wall-clock time for one request.
public struct SimulationExecutionPolicy: Codable, Equatable, Sendable {
    public var timeoutMilliseconds: Int?
    public var maximumRequestBytes: Int
    public var maximumResultBytes: Int
    public var maximumNodes: Int
    public var maximumDevices: Int
    public var maximumParallelism: Int

    public init(
        timeoutMilliseconds: Int? = nil,
        maximumRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumResultBytes: Int = 64 * 1_024 * 1_024,
        maximumNodes: Int = 100_000,
        maximumDevices: Int = 200_000,
        maximumParallelism: Int = 1
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResultBytes = maximumResultBytes
        self.maximumNodes = maximumNodes
        self.maximumDevices = maximumDevices
        self.maximumParallelism = maximumParallelism
    }

    public func validate() throws {
        guard timeoutMilliseconds.map({ $0 > 0 }) ?? true,
              maximumRequestBytes > 0, maximumResultBytes > 0,
              maximumNodes > 0, maximumDevices > 0,
              (1...32).contains(maximumParallelism) else {
            throw SimulationHostContractError.invalidExecutionPolicy
        }
    }
}

public enum SimulationBatchItemState: String, Codable, Sendable {
    case executed
    case skipped
}

public struct SimulationBatchRequest<Request: Codable & Sendable>: Codable, Sendable {
    public let contractVersion: Int
    public let batchID: String
    public let failFast: Bool
    public let requests: [Request]

    public init(
        contractVersion: Int = SimulationHostContract.currentVersion,
        batchID: String,
        failFast: Bool = false,
        requests: [Request]
    ) {
        self.contractVersion = contractVersion
        self.batchID = batchID
        self.failFast = failFast
        self.requests = requests
    }
}

public struct SimulationBatchItem<Response: Codable & Sendable>: Codable, Sendable {
    public let index: Int
    public let state: SimulationBatchItemState
    public let response: Response?
    public let reason: String?

    public init(index: Int, state: SimulationBatchItemState, response: Response?, reason: String? = nil) {
        self.index = index
        self.state = state
        self.response = response
        self.reason = reason
    }
}

public struct SimulationBatchResponse<Response: Codable & Sendable>: Codable, Sendable {
    public let contractVersion: Int
    public let batchID: String
    public let items: [SimulationBatchItem<Response>]
    public let error: String?

    public init(
        contractVersion: Int = SimulationHostContract.currentVersion,
        batchID: String,
        items: [SimulationBatchItem<Response>],
        error: String? = nil
    ) {
        self.contractVersion = contractVersion
        self.batchID = batchID
        self.items = items.sorted { $0.index < $1.index }
        self.error = error
    }

    /// True when the host represented every item with an executed response.
    /// The generic envelope cannot infer application-level success.
    public var completed: Bool {
        error == nil && items.allSatisfy { $0.state == .executed && $0.response != nil }
    }
}

/// Thread-safe cancellation bridge for callers that cannot directly retain a
/// Swift Task, including Objective-C and service adapters.
public final class SimulationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum SimulationHostContractError: LocalizedError, Equatable {
    case invalidExecutionPolicy
    case unsupportedBatchVersion(Int)
    case invalidBatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExecutionPolicy:
            return "The simulation execution policy is invalid."
        case .unsupportedBatchVersion(let version):
            return "Simulation batch contract version \(version) is not supported."
        case .invalidBatch(let message):
            return message
        }
    }
}
