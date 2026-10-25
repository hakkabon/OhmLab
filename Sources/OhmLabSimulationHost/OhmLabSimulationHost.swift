@_exported import OhmLabSimulationProtocol
import Foundation
import OhmLabCore

public typealias PortableSimulationBatchRequest =
    SimulationBatchRequest<PortableSimulationPlatform.Request>
public typealias PortableSimulationBatchResponse =
    SimulationBatchResponse<PortableSimulationPlatform.Response>

/// Runtime for the portable wire contract. Protocol-only clients can depend on
/// OhmLabSimulationProtocol without linking a solver, NumericCore, or app code.
public enum OhmLabSimulationHost {
    private enum RaceOutcome: Sendable {
        case response(PortableSimulationPlatform.Response)
        case timedOut
        case cancelled
    }

    public static var manifest: PortableSimulationPlatform.Manifest {
        PortableSimulationPlatform.manifest
    }

    /// Compatibility synchronous entry point. New service integrations should
    /// use the async policy-aware overload so deadlines can cancel solver work.
    public static func execute(_ data: Data) -> PortableSimulationPlatform.Response {
        PortableSimulationPlatform.execute(data)
    }

    public static func execute(
        _ data: Data,
        policy: SimulationExecutionPolicy = .init(),
        cancellationToken: SimulationCancellationToken? = nil
    ) async -> PortableSimulationPlatform.Response {
        do {
            try policy.validate()
            guard data.count <= policy.maximumRequestBytes else {
                return failure(requestID: "", code: .invalidRequest, message: "request exceeds host byte budget")
            }
            let request = try PortableSimulationPlatform.decodeRequest(data)
            return await execute(request, policy: policy, cancellationToken: cancellationToken)
        } catch {
            return failure(requestID: "", code: .invalidRequest, message: error.localizedDescription)
        }
    }

    public static func execute(
        _ request: PortableSimulationPlatform.Request,
        policy: SimulationExecutionPolicy = .init(),
        cancellationToken: SimulationCancellationToken? = nil
    ) async -> PortableSimulationPlatform.Response {
        do { try policy.validate() }
        catch {
            return failure(requestID: request.requestID, code: .invalidRequest, message: error.localizedDescription)
        }
        guard request.circuit.nodes.count <= policy.maximumNodes,
              request.circuit.devices.count <= policy.maximumDevices else {
            return failure(requestID: request.requestID, code: .invalidRequest,
                           message: "request exceeds host circuit budget")
        }
        guard let encoded = try? PortableSimulationPlatform.encode(request),
              encoded.count <= policy.maximumRequestBytes else {
            return failure(requestID: request.requestID, code: .invalidRequest,
                           message: "request exceeds host byte budget")
        }
        guard cancellationToken?.isCancelled != true, !Task.isCancelled else {
            return failure(requestID: request.requestID, code: .simulationFailed,
                           message: "simulation cancelled")
        }

        let response: PortableSimulationPlatform.Response
        if policy.timeoutMilliseconds == nil && cancellationToken == nil {
            response = PortableSimulationPlatform.execute(request)
        } else {
            response = await race(
                request: request,
                timeoutMilliseconds: policy.timeoutMilliseconds,
                cancellationToken: cancellationToken
            )
        }
        guard let resultData = try? PortableSimulationPlatform.encode(response),
              resultData.count <= policy.maximumResultBytes else {
            return failure(requestID: request.requestID, code: .simulationFailed,
                           message: "result exceeds host byte budget", backend: response.backend)
        }
        return response
    }

    public static func executeBatch(
        _ batch: PortableSimulationBatchRequest,
        policy: SimulationExecutionPolicy = .init(),
        cancellationToken: SimulationCancellationToken? = nil
    ) async -> PortableSimulationBatchResponse {
        do {
            try policy.validate()
            guard batch.contractVersion == SimulationHostContract.currentVersion else {
                throw SimulationHostContractError.unsupportedBatchVersion(batch.contractVersion)
            }
            guard !batch.batchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  batch.batchID.utf8.count <= 256,
                  !batch.requests.isEmpty,
                  batch.requests.count <= SimulationHostContract.maximumBatchItems else {
                throw SimulationHostContractError.invalidBatch(
                    "batchID and request count must satisfy the host contract"
                )
            }
        } catch {
            return .init(batchID: batch.batchID, items: [], error: error.localizedDescription)
        }

        if batch.failFast {
            var items: [SimulationBatchItem<PortableSimulationPlatform.Response>] = []
            var stopped = false
            for (index, request) in batch.requests.enumerated() {
                if stopped {
                    items.append(.init(index: index, state: .skipped, response: nil,
                                       reason: "skipped after fail-fast failure"))
                    continue
                }
                let response = await execute(request, policy: policy, cancellationToken: cancellationToken)
                items.append(.init(index: index, state: .executed, response: response))
                stopped = !response.succeeded
            }
            return .init(batchID: batch.batchID, items: items)
        }

        let requests = batch.requests
        let parallelism = min(policy.maximumParallelism, requests.count)
        let items = await withTaskGroup(
            of: SimulationBatchItem<PortableSimulationPlatform.Response>.self,
            returning: [SimulationBatchItem<PortableSimulationPlatform.Response>].self
        ) { group in
            var nextIndex = 0
            var completed: [SimulationBatchItem<PortableSimulationPlatform.Response>] = []
            func enqueue(_ index: Int) {
                group.addTask {
                    let response = await execute(
                        requests[index], policy: policy, cancellationToken: cancellationToken
                    )
                    return .init(index: index, state: .executed, response: response)
                }
            }
            while nextIndex < parallelism { enqueue(nextIndex); nextIndex += 1 }
            while let item = await group.next() {
                completed.append(item)
                if nextIndex < requests.count { enqueue(nextIndex); nextIndex += 1 }
            }
            return completed.sorted { $0.index < $1.index }
        }
        return .init(batchID: batch.batchID, items: items)
    }

    private static func race(
        request: PortableSimulationPlatform.Request,
        timeoutMilliseconds: Int?,
        cancellationToken: SimulationCancellationToken?
    ) async -> PortableSimulationPlatform.Response {
        let outcome = await withTaskGroup(of: RaceOutcome.self, returning: RaceOutcome.self) { group in
            group.addTask { .response(PortableSimulationPlatform.execute(request)) }
            group.addTask {
                let clock = ContinuousClock()
                let deadline = timeoutMilliseconds.map { clock.now.advanced(by: .milliseconds($0)) }
                while true {
                    if Task.isCancelled || cancellationToken?.isCancelled == true { return .cancelled }
                    if let deadline, clock.now >= deadline { return .timedOut }
                    do { try await clock.sleep(for: .milliseconds(5)) }
                    catch { return .cancelled }
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        switch outcome {
        case .response(let response): return response
        case .timedOut:
            return failure(requestID: request.requestID, code: .simulationFailed,
                           message: "simulation deadline exceeded", backend: request.backend)
        case .cancelled:
            return failure(requestID: request.requestID, code: .simulationFailed,
                           message: "simulation cancelled", backend: request.backend)
        }
    }

    private static func failure(
        requestID: String,
        code: PortableSimulationPlatform.ErrorCode,
        message: String,
        backend: String? = nil
    ) -> PortableSimulationPlatform.Response {
        .init(
            protocolVersion: PortableSimulationPlatform.currentContractVersion,
            requestID: requestID,
            status: .failure,
            backend: backend,
            implementationVersion: nil,
            provenance: nil,
            result: nil,
            error: .init(code: code, message: message)
        )
    }
}
