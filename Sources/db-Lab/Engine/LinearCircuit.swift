// LinearCircuit.swift
// A dependency-free Modified Nodal Analysis (MNA) engine.
//
// Supported elements: resistor, capacitor, inductor, independent voltage source,
// independent current source, a Shockley diode, NPN/PNP bipolar transistors
// (simplified Ebers-Moll transport model), and N-MOS/P-MOS field-effect
// transistors (Level 1 Shichman-Hodges). The nonlinear devices force DC,
// operating-point, and transient solves through a damped Newton-Raphson
// iteration that repeatedly linearises each device about its current bias point.
// AC analysis linearises once about the DC operating point (small-signal). The
// Newton machinery is generic over N-terminal devices: each device reports its
// terminal currents and Jacobian, which are stamped as a block.
//
// Node indexing convention: node `0` is the ground reference. Matrix rows and
// columns 0..<n-1 correspond to circuit nodes 1...n-1. Voltage source branch
// currents occupy the remaining rows/columns.

import Foundation

public enum CircuitSolveError: LocalizedError {
    case noGround
    case noNodes
    case invalidElement(String)
    case unsupportedElement(String)
    case didNotConverge(String)

    public var errorDescription: String? {
        switch self {
        case .noGround:
            return "The circuit has no ground (node 0) reference."
        case .noNodes:
            return "The circuit contains no nodes to solve."
        case .invalidElement(let name):
            return "Element \(name) has an invalid or non-positive value."
        case .unsupportedElement(let name):
            return "Element \(name) is not supported by the linear solver yet."
        case .didNotConverge(let name):
            return "The nonlinear solve did not converge near \(name). Check the bias point."
        }
    }
}

public struct LinearCircuit: Sendable {
    public enum ElementKind: String, Sendable {
        case resistor
        case capacitor
        case inductor
        case voltageSource
        case currentSource
        case diode
        case bjt
        case mosfet
    }

    public enum BJTPolarity: String, Sendable {
        case npn
        case pnp
    }

    public enum MOSFETPolarity: String, Sendable {
        case nmos
        case pmos
    }

    /// Simplified Ebers-Moll transport model. Early voltage is not modelled.
    public struct BJTParameters: Sendable, Equatable {
        public var polarity: BJTPolarity
        public var saturationCurrent: Double
        public var forwardBeta: Double
        public var reverseBeta: Double
        public var thermalVoltage: Double

        public init(
            polarity: BJTPolarity = .npn,
            saturationCurrent: Double = 1e-15,
            forwardBeta: Double = 100,
            reverseBeta: Double = 1,
            thermalVoltage: Double = 0.025_852
        ) {
            self.polarity = polarity
            self.saturationCurrent = saturationCurrent
            self.forwardBeta = forwardBeta
            self.reverseBeta = reverseBeta
            self.thermalVoltage = thermalVoltage
        }
    }

    /// Level 1 Shichman-Hodges MOSFET parameters. `thresholdVoltage` is the
    /// signed SPICE VTO (positive for an N-MOS, negative for a P-MOS); the
    /// characteristic derives the positive threshold from the polarity. Body
    /// effect is included through `bodyEffect` (GAMMA) and `surfacePotential`
    /// (PHI); a GAMMA of zero disables it. Channel-length modulation is
    /// modelled by `lambda`.
    public struct MOSFETParameters: Sendable, Equatable {
        public var polarity: MOSFETPolarity
        public var thresholdVoltage: Double
        public var transconductanceParameter: Double
        public var channelLengthModulation: Double
        public var bodyEffect: Double
        public var surfacePotential: Double

        public init(
            polarity: MOSFETPolarity = .nmos,
            thresholdVoltage: Double = 1,
            transconductanceParameter: Double = 2e-5,
            channelLengthModulation: Double = 0,
            bodyEffect: Double = 0,
            surfacePotential: Double = 0.6
        ) {
            self.polarity = polarity
            self.thresholdVoltage = thresholdVoltage
            self.transconductanceParameter = transconductanceParameter
            self.channelLengthModulation = channelLengthModulation
            self.bodyEffect = bodyEffect
            self.surfacePotential = surfacePotential
        }
    }

    /// Shockley diode parameters. `saturationCurrent` is scaled by `area`.
    public struct DiodeParameters: Sendable, Equatable {
        public var saturationCurrent: Double
        public var emissionCoefficient: Double
        public var thermalVoltage: Double
        public var area: Double

        public init(
            saturationCurrent: Double = 1e-14,
            emissionCoefficient: Double = 1,
            thermalVoltage: Double = 0.025_852,
            area: Double = 1
        ) {
            self.saturationCurrent = saturationCurrent
            self.emissionCoefficient = emissionCoefficient
            self.thermalVoltage = thermalVoltage
            self.area = area
        }

        /// Effective saturation current, including the area multiplier.
        var effectiveSaturationCurrent: Double { saturationCurrent * area }
        /// Thermal voltage times the emission coefficient.
        var junctionVoltage: Double { emissionCoefficient * thermalVoltage }
    }

    public struct Element: Sendable {
        public var kind: ElementKind
        public var nodeA: Int
        public var nodeB: Int
        /// Third terminal, used by three- and four-terminal devices. For a BJT
        /// the terminal convention is nodeA = collector, nodeB = emitter,
        /// nodeC = base. For a MOSFET it is nodeA = drain, nodeB = source,
        /// nodeC = gate.
        public var nodeC: Int?
        /// Fourth terminal, used by four-terminal devices. For a MOSFET it is
        /// the bulk (body) node.
        public var nodeD: Int?
        /// Resistance, capacitance, inductance, or a source's fallback magnitude.
        public var value: Double
        public var phaseDegrees: Double
        /// DC magnitude for a source. When nil the source uses `value` for DC.
        public var dcValue: Double?
        /// AC magnitude for a source. When nil the source uses `value` for AC.
        public var acValue: Double?
        /// Time-domain shape for a source, used by transient analysis. When nil
        /// the source is constant at its DC magnitude.
        public var transient: Waveform?
        /// Shockley parameters for a diode element; nil for every other kind.
        public var diode: DiodeParameters?
        /// Ebers-Moll parameters for a BJT element; nil for every other kind.
        public var bjt: BJTParameters?
        /// Level 1 parameters for a MOSFET element; nil for every other kind.
        public var mosfet: MOSFETParameters?
        public var name: String

        public init(
            kind: ElementKind,
            nodeA: Int,
            nodeB: Int,
            nodeC: Int? = nil,
            nodeD: Int? = nil,
            value: Double,
            phaseDegrees: Double = 0,
            dcValue: Double? = nil,
            acValue: Double? = nil,
            transient: Waveform? = nil,
            diode: DiodeParameters? = nil,
            bjt: BJTParameters? = nil,
            mosfet: MOSFETParameters? = nil,
            name: String
        ) {
            self.kind = kind
            self.nodeA = nodeA
            self.nodeB = nodeB
            self.nodeC = nodeC
            self.nodeD = nodeD
            self.value = value
            self.phaseDegrees = phaseDegrees
            self.dcValue = dcValue
            self.acValue = acValue
            self.transient = transient
            self.diode = diode
            self.bjt = bjt
            self.mosfet = mosfet
            self.name = name
        }

        /// Magnitude used for the given analysis. A source with a single value
        /// (the common case) uses that value for both DC and AC.
        func magnitude(isDC: Bool) -> Double {
            isDC ? (dcValue ?? value) : (acValue ?? value)
        }

        /// Source value at a point in time. A source without an explicit
        /// waveform is constant at its DC magnitude.
        func transientValue(at time: Double) -> Double {
            if let transient { return transient.value(at: time) }
            return dcValue ?? value
        }
    }

    /// Node names indexed by node number; index 0 is always the ground reference.
    public var nodeNames: [String]
    public var elements: [Element]

    public init(nodeNames: [String], elements: [Element]) {
        self.nodeNames = nodeNames
        self.elements = elements
    }

    public var nodeCount: Int { nodeNames.count }

    public struct Solution: Sendable {
        /// Complex node voltage indexed by node number (index 0 is ground = 0).
        public var nodeVoltages: [Complex]
        /// Branch current flowing from node A to node B through each voltage source.
        public var sourceCurrents: [(name: String, current: Complex)]
        /// True for DC solves, where every value is real.
        public var isDC: Bool
        /// Optional per-element current, in the same order as `elements`.
        public var elementCurrents: [Complex]

        public func voltage(node: Int) -> Complex {
            guard node >= 0, node < nodeVoltages.count else { return .zero }
            return nodeVoltages[node]
        }
    }

    // MARK: - Analysis modes

    /// How an assembly pass interprets reactive elements.
    private enum AnalysisMode {
        /// Capacitors open, inductors short; sources use their DC magnitude.
        case dc
        /// DC topology, but sources take their value at `time` from their
        /// transient waveform. Used for the transient initial condition.
        case operatingPoint(time: Double)
        case ac(omega: Double)
        case transient(
            timestep: Double,
            time: Double,
            capacitorVoltage: [Double],
            inductorCurrent: [Double]
        )

        /// Whether inductors are ideal shorts (a 0 V branch) and capacitors are
        /// open circuits.
        var usesDCStamps: Bool {
            switch self {
            case .dc, .operatingPoint: return true
            case .ac, .transient: return false
            }
        }

        var isDC: Bool {
            if case .dc = self { return true }
            return false
        }

        var isAC: Bool {
            if case .ac = self { return true }
            return false
        }
    }

    // MARK: - Nonlinear device support

    /// Any nonlinear element forces an iterative (Newton-Raphson) solve.
    private static func isNonlinear(_ kind: ElementKind) -> Bool {
        kind == .diode || kind == .bjt || kind == .mosfet
    }

    public var hasNonlinear: Bool {
        elements.contains { LinearCircuit.isNonlinear($0.kind) }
    }

    private var nonlinearIndices: [Int] {
        elements.indices.filter { LinearCircuit.isNonlinear(elements[$0].kind) }
    }

    /// Ordered terminal nodes of a nonlinear device. BJT order is
    /// [base, collector, emitter] and MOSFET order is
    /// [drain, gate, source, bulk] to match the characteristic derivations.
    private func terminalNodes(for element: Element) -> [Int] {
        switch element.kind {
        case .diode:
            return [element.nodeA, element.nodeB]
        case .bjt:
            return [element.nodeC ?? element.nodeB, element.nodeA, element.nodeB]
        case .mosfet:
            let source = element.nodeB
            return [element.nodeA, element.nodeC ?? source, source, element.nodeD ?? source]
        default:
            return []
        }
    }

    /// Shockley current and small-signal conductance at a junction voltage.
    private func diodeCurrentAndConductance(
        _ element: Element,
        voltage: Double
    ) -> (current: Double, conductance: Double) {
        guard let model = element.diode else { return (0, 0) }
        let vt = model.junctionVoltage
        guard vt > 0 else { return (0, 0) }
        let isat = model.effectiveSaturationCurrent
        // Clamp the exponent so extreme forward bias cannot overflow.
        let exponent = min(voltage / vt, 80)
        let expValue = exp(exponent)
        return (isat * (expValue - 1), isat * expValue / vt)
    }

    /// Terminal currents into a nonlinear device and the Jacobian
    /// `J[i][j] = ∂I_i/∂V_j` at the given terminal voltages.
    private func nonlinearCharacteristic(
        _ element: Element,
        terminals: [Double]
    ) -> (currents: [Double], jacobian: [[Double]]) {
        switch element.kind {
        case .diode:
            let (current, conductance) = diodeCurrentAndConductance(element, voltage: terminals[0] - terminals[1])
            return ([current, -current], [[conductance, -conductance], [-conductance, conductance]])
        case .bjt:
            return bjtCharacteristic(element, terminals: terminals)
        case .mosfet:
            return mosfetCharacteristic(element, terminals: terminals)
        default:
            let zero = [Double](repeating: 0, count: terminals.count)
            return (zero, Array(repeating: zero, count: terminals.count))
        }
    }

    /// Ebers-Moll transport characteristic for a BJT. Terminal order is
    /// [base, collector, emitter]; terminal currents are those flowing *into*
    /// the device. For a PNP both the controlling voltages and the currents flip.
    private func bjtCharacteristic(
        _ element: Element,
        terminals: [Double]
    ) -> (currents: [Double], jacobian: [[Double]]) {
        guard let model = element.bjt else {
            let zero = [Double](repeating: 0, count: 3)
            return (zero, Array(repeating: zero, count: 3))
        }
        let sign = model.polarity == .pnp ? -1.0 : 1.0
        let vt = model.thermalVoltage
        let isat = model.saturationCurrent
        let (vb, vc, ve) = (terminals[0], terminals[1], terminals[2])

        let vbe = sign * (vb - ve)
        let vbc = sign * (vb - vc)
        let ebe = exp(min(vbe / vt, 80))
        let ebc = exp(min(vbc / vt, 80))
        let cbe = ebe - 1
        let cbc = ebc - 1

        let isBF = isat / model.forwardBeta
        let isBR = isat / model.reverseBeta
        let ibe = isBF * cbe
        let ibc = isBR * cbc
        let ict = isat * (cbe - cbc)

        // Terminal currents in the polarity-flipped frame.
        let baseCurrent = ibe + ibc
        let collectorCurrent = ict - ibc
        let emitterCurrent = -(ibe + ict)

        let gbe = isBF * ebe / vt
        let gbc = isBR * ebc / vt
        let gm = isat * ebe / vt
        let gmr = isat * ebc / vt

        // Convert derivatives w.r.t. (vbe, vbc) into w.r.t. terminal voltages.
        func rows(_ dVbe: Double, _ dVbc: Double) -> [Double] {
            [dVbe + dVbc, -dVbc, -dVbe]
        }
        return (
            [sign * baseCurrent, sign * collectorCurrent, sign * emitterCurrent],
            [
                rows(gbe, gbc),
                rows(gm, -(gmr + gbc)),
                rows(-(gbe + gm), gmr)
            ]
        )
    }

    /// Level 1 Shichman-Hodges MOSFET characteristic. Terminal order is
    /// [drain, gate, source, bulk]; terminal currents are those flowing into
    /// the device. A P-MOS is handled by flipping the controlling voltages and
    /// the current with `sign`, exactly as the BJT characteristic does.
    private func mosfetCharacteristic(
        _ element: Element,
        terminals: [Double]
    ) -> (currents: [Double], jacobian: [[Double]]) {
        let zeroRow = [Double](repeating: 0, count: 4)
        guard let model = element.mosfet, model.transconductanceParameter > 0 else {
            return (zeroRow, Array(repeating: zeroRow, count: 4))
        }
        let sign = model.polarity == .pmos ? -1.0 : 1.0
        let (vd, vg, vs, vb) = (terminals[0], terminals[1], terminals[2], terminals[3])

        // Control voltages in the sign-flipped (n-channel) frame.
        let vgs = sign * (vg - vs)
        let vds = sign * (vd - vs)
        let vbs = sign * (vb - vs)

        // Positive threshold, including the body effect.
        let phi = max(model.surfacePotential, 1e-3)
        let phiMinusVbs = max(phi - vbs, 1e-9)
        let sqrtTerm = phiMinusVbs.squareRoot()
        let threshold = sign * model.thresholdVoltage
            + model.bodyEffect * (sqrtTerm - phi.squareRoot())
        let overdrive = vgs - threshold
        // d(overdrive)/d(vbs) = + GAMMA / (2·sqrt(PHI − vbs)).
        let dOverdriveDVbs = model.bodyEffect / (2 * sqrtTerm)

        // A tiny drain-source conductance keeps the nodal matrix non-singular
        // when the device is cut off, matching SPICE's GMIN.
        let gmin = 1e-12
        var drainSourceCurrent = gmin * vds
        var gVgs = 0.0
        var gVds = gmin
        var gVbs = 0.0

        if overdrive > 0 {
            let kp = model.transconductanceParameter
            let lambdaFactor = 1 + model.channelLengthModulation * vds
            if vds < overdrive {
                // Triode (linear) region.
                drainSourceCurrent += kp * (overdrive * vds - 0.5 * vds * vds) * lambdaFactor
                gVgs = kp * vds * lambdaFactor
                gVds = kp * (overdrive - vds) * lambdaFactor
                    + kp * (overdrive * vds - 0.5 * vds * vds) * model.channelLengthModulation
            } else {
                // Saturation region.
                drainSourceCurrent += 0.5 * kp * overdrive * overdrive * lambdaFactor
                gVgs = kp * overdrive * lambdaFactor
                gVds = 0.5 * kp * overdrive * overdrive * model.channelLengthModulation
            }
            gVbs = gVgs * dOverdriveDVbs
        }

        // The returned current is sign * Ids; the polarity sign cancels in its
        // derivative, so the Jacobian rows are the "pure" derivatives with
        // respect to terminal voltage.
        let drainRow = [gVds, gVgs, -(gVgs + gVds + gVbs), gVbs]
        let sourceRow = drainRow.map { -$0 }
        let drainCurrent = sign * drainSourceCurrent
        return (
            [drainCurrent, 0, -drainCurrent, 0],
            [drainRow, zeroRow, sourceRow, zeroRow]
        )
    }

    /// Limits a junction voltage update (a form of SPICE's pnjlim), keeping the
    /// exponential from overshooting the forward operating region.
    private func limitedJunction(_ value: Double, previous: Double, vt: Double, isat: Double) -> Double {
        guard vt > 0, isat > 0 else { return value }
        let critical = vt * log(vt / (2.0.squareRoot() * isat))
        if value > critical, abs(value - previous) > 2 * vt {
            if previous > 0 {
                let arg = 1 + (value - previous) / vt
                return arg > 0 ? previous + vt * log(arg) : critical
            }
            return vt * log(max(value, .leastNormalMagnitude) / vt)
        }
        return max(value, -1_000)
    }

    /// Applies junction limiting to raw terminal voltages from a solve.
    private func limitedTerminals(_ element: Element, raw: [Double], previous: [Double]) -> [Double] {
        switch element.kind {
        case .diode:
            guard let model = element.diode else { return raw }
            let junction = limitedJunction(
                raw[0] - raw[1],
                previous: previous[0] - previous[1],
                vt: model.junctionVoltage,
                isat: model.effectiveSaturationCurrent
            )
            return [raw[1] + junction, raw[1]]
        case .bjt:
            guard let model = element.bjt else { return raw }
            let sign = model.polarity == .pnp ? -1.0 : 1.0
            let vbe = limitedJunction(
                sign * (raw[0] - raw[2]),
                previous: sign * (previous[0] - previous[2]),
                vt: model.thermalVoltage,
                isat: model.saturationCurrent
            )
            let vbc = limitedJunction(
                sign * (raw[0] - raw[1]),
                previous: sign * (previous[0] - previous[1]),
                vt: model.thermalVoltage,
                isat: model.saturationCurrent
            )
            let ve = raw[2]
            let vb = ve + sign * vbe
            let vc = vb - sign * vbc
            return [vb, vc, ve]
        case .mosfet:
            // The Level 1 characteristic is piecewise polynomial, so no
            // exponential limiting is required.
            return raw
        default:
            return raw
        }
    }

    /// Terminal voltages of every nonlinear device at a solved point, usable as
    /// a warm-start bias for the next Newton iteration (e.g. the next transient
    /// step).
    func nonlinearState(from solution: Solution) -> [Int: [Double]] {
        var state: [Int: [Double]] = [:]
        for index in nonlinearIndices {
            let element = elements[index]
            state[index] = terminalNodes(for: element).map { solution.nodeVoltages[$0].re }
        }
        return state
    }

    // MARK: - DC operating point

    public func solveDC() throws -> Solution {
        try validate()
        return try solveNonlinear(mode: .dc)
    }

    /// DC topology (capacitors open, inductors short) with time-domain source
    /// values. This is the initial condition for a transient run.
    public func solveOperatingPoint(atTime time: Double, nonlinearState: [Int: [Double]] = [:]) throws -> Solution {
        try validate()
        return try solveNonlinear(mode: .operatingPoint(time: time), initialState: nonlinearState)
    }

    // MARK: - AC solve at a single frequency (small-signal)

    public func solveAC(frequencyHz: Double) throws -> Solution {
        try validate()
        guard frequencyHz > 0, frequencyHz.isFinite else {
            throw CircuitSolveError.invalidElement("AC frequency")
        }
        // Small-signal AC linearises every nonlinear device about the DC
        // operating point.
        var state: [Int: [Double]] = [:]
        if hasNonlinear {
            state = nonlinearState(from: try solveNonlinear(mode: .dc))
        }
        return try assembleOnce(mode: .ac(omega: 2 * .pi * frequencyHz), nonlinearState: state)
    }

    // MARK: - Transient step

    /// Advance the circuit one time step using backward Euler companion models.
    /// `capacitorVoltage` and `inductorCurrent` hold the previous state, indexed
    /// by `elements`; callers update them from the returned solution.
    func solveTransientStep(
        timestep: Double,
        time: Double,
        capacitorVoltage: [Double],
        inductorCurrent: [Double],
        nonlinearState: [Int: [Double]] = [:]
    ) throws -> Solution {
        try validate()
        guard timestep > 0, timestep.isFinite else {
            throw CircuitSolveError.invalidElement("Transient timestep")
        }
        return try solveNonlinear(
            mode: .transient(
                timestep: timestep,
                time: time,
                capacitorVoltage: capacitorVoltage,
                inductorCurrent: inductorCurrent
            ),
            initialState: nonlinearState
        )
    }

    /// Newton-Raphson for circuits with nonlinear elements; a single pass when
    /// the circuit is purely linear.
    private func solveNonlinear(mode: AnalysisMode, initialState: [Int: [Double]] = [:]) throws -> Solution {
        let indices = nonlinearIndices
        guard !indices.isEmpty else {
            return try assembleOnce(mode: mode, nonlinearState: initialState)
        }

        var state = initialState
        var solution = try assembleOnce(mode: mode, nonlinearState: state)
        for _ in 0..<200 {
            var maxDelta = 0.0
            var maxVoltage = 0.0
            var next: [Int: [Double]] = [:]
            for index in indices {
                let element = elements[index]
                let terminals = terminalNodes(for: element)
                let raw = terminals.map { solution.nodeVoltages[$0].re }
                let previous = state[index] ?? [Double](repeating: 0, count: terminals.count)
                let limited = limitedTerminals(element, raw: raw, previous: previous)
                next[index] = limited
                for (newValue, oldValue) in zip(limited, previous) {
                    maxDelta = max(maxDelta, abs(newValue - oldValue))
                }
                maxVoltage = max(maxVoltage, limited.map(abs).max() ?? 0)
            }
            state = next
            solution = try assembleOnce(mode: mode, nonlinearState: state)
            if maxDelta < 1e-6 + 1e-3 * maxVoltage { return solution }
        }
        throw CircuitSolveError.didNotConverge(elements[indices[0]].name)
    }

    private func validate() throws {
        guard nodeCount > 1 else { throw CircuitSolveError.noNodes }
        for element in elements {
            switch element.kind {
            case .resistor, .capacitor, .inductor:
                guard element.value.isFinite, element.value > 0 else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            case .voltageSource, .currentSource:
                guard element.value.isFinite,
                      element.dcValue?.isFinite ?? true,
                      element.acValue?.isFinite ?? true else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            case .diode:
                guard let model = element.diode,
                      model.saturationCurrent.isFinite,
                      model.saturationCurrent > 0,
                      model.emissionCoefficient.isFinite,
                      model.emissionCoefficient > 0,
                      model.thermalVoltage.isFinite,
                      model.thermalVoltage > 0,
                      model.area.isFinite,
                      model.area > 0 else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            case .bjt:
                guard let model = element.bjt,
                      model.saturationCurrent.isFinite,
                      model.saturationCurrent > 0,
                      model.forwardBeta.isFinite,
                      model.forwardBeta > 1,
                      model.reverseBeta.isFinite,
                      model.reverseBeta > 0,
                      model.thermalVoltage.isFinite,
                      model.thermalVoltage > 0 else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            case .mosfet:
                guard let model = element.mosfet,
                      model.thresholdVoltage.isFinite,
                      model.transconductanceParameter.isFinite,
                      model.transconductanceParameter > 0,
                      model.channelLengthModulation.isFinite,
                      model.channelLengthModulation >= 0,
                      model.bodyEffect.isFinite,
                      model.bodyEffect >= 0,
                      model.surfacePotential.isFinite,
                      model.surfacePotential > 0 else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            }
        }
    }

    // MARK: - Matrix assembly

    private struct Branch {
        var element: Element
        /// Index into `elements`, so the solved branch current can be attached
        /// to the originating element.
        var elementIndex: Int
        var voltage: Complex
    }

    private func assembleOnce(mode: AnalysisMode, nonlinearState: [Int: [Double]]) throws -> Solution {
        let nodeCount = nodeNames.count
        let nodeRows = nodeCount - 1

        func sourceMagnitude(_ element: Element) -> Double {
            switch mode {
            case .dc:
                return element.magnitude(isDC: true)
            case .operatingPoint(let time), .transient(_, let time, _, _):
                return element.transientValue(at: time)
            case .ac:
                return element.magnitude(isDC: false)
            }
        }

        func sourcePhase(_ element: Element) -> Double {
            mode.isDC ? 0 : element.phaseDegrees
        }

        // Collect voltage-source-like branches. At DC (and for the transient
        // initial condition) an inductor behaves as a zero-volt source (an ideal
        // short); in AC and transient it is stamped as an admittance.
        var branches: [Branch] = []
        for (index, element) in elements.enumerated() {
            switch element.kind {
            case .voltageSource:
                branches.append(Branch(
                    element: element,
                    elementIndex: index,
                    voltage: Complex.fromPolar(
                        magnitude: sourceMagnitude(element),
                        phaseDegrees: sourcePhase(element)
                    )
                ))
            case .inductor where mode.usesDCStamps:
                branches.append(Branch(element: element, elementIndex: index, voltage: .zero))
            default:
                break
            }
        }

        let dimension = nodeRows + branches.count
        guard dimension > 0 else { throw CircuitSolveError.noNodes }

        var matrix = [[Complex]](repeating: [Complex](repeating: .zero, count: dimension), count: dimension)
        var rhs = [Complex](repeating: .zero, count: dimension)

        func row(_ node: Int) -> Int? {
            node == 0 ? nil : node - 1
        }

        func stampAdmittance(a: Int, b: Int, y: Complex) {
            if let i = row(a) { matrix[i][i] = matrix[i][i] + y }
            if let j = row(b) { matrix[j][j] = matrix[j][j] + y }
            if let i = row(a), let j = row(b) {
                matrix[i][j] = matrix[i][j] - y
                matrix[j][i] = matrix[j][i] - y
            }
        }

        func stampCurrentSource(a: Int, b: Int, current: Complex) {
            if let i = row(a) { rhs[i] = rhs[i] - current }
            if let j = row(b) { rhs[j] = rhs[j] + current }
        }

        // Stamps an N-terminal nonlinear device from its terminal currents and
        // Jacobian at a linearisation point. `incremental` (AC) keeps only the
        // Jacobian, giving the small-signal model with no bias offset.
        func stampNonlinear(
            nodes: [Int],
            currents: [Double],
            jacobian: [[Double]],
            voltages: [Double],
            incremental: Bool
        ) {
            for i in nodes.indices where i < jacobian.count {
                for j in nodes.indices where j < jacobian[i].count {
                    if let r = row(nodes[i]), let c = row(nodes[j]) {
                        matrix[r][c] = matrix[r][c] + Complex(jacobian[i][j], 0)
                    }
                }
                if !incremental, let r = row(nodes[i]), i < currents.count {
                    var jv = 0.0
                    for j in nodes.indices where j < jacobian[i].count && j < voltages.count {
                        jv += jacobian[i][j] * voltages[j]
                    }
                    rhs[r] = rhs[r] - Complex(currents[i] - jv, 0)
                }
            }
        }

        for (index, element) in elements.enumerated() {
            switch element.kind {
            case .resistor:
                stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(1 / element.value, 0))
            case .capacitor:
                switch mode {
                case .ac(let omega):
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(0, omega * element.value))
                case .transient(let timestep, _, let capacitorVoltage, _):
                    // Backward Euler: i = G·v − G·v_prev, with G = C/Δt.
                    let conductance = element.value / timestep
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(conductance, 0))
                    let history = -conductance * capacitorVoltage[index]
                    stampCurrentSource(a: element.nodeA, b: element.nodeB, current: Complex(history, 0))
                case .dc, .operatingPoint:
                    break // open circuit
                }
            case .inductor:
                switch mode {
                case .ac(let omega):
                    let admittance = Complex(1, 0) / Complex(0, omega * element.value)
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: admittance)
                case .transient(let timestep, _, _, let inductorCurrent):
                    // Backward Euler: i = G·v + i_prev, with G = Δt/L.
                    let conductance = timestep / element.value
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(conductance, 0))
                    stampCurrentSource(a: element.nodeA, b: element.nodeB, current: Complex(inductorCurrent[index], 0))
                case .dc, .operatingPoint:
                    break // handled as a 0 V branch
                }
            case .voltageSource:
                break // stamped below with its branch unknown
            case .currentSource:
                stampCurrentSource(
                    a: element.nodeA,
                    b: element.nodeB,
                    current: Complex.fromPolar(
                        magnitude: sourceMagnitude(element),
                        phaseDegrees: sourcePhase(element)
                    )
                )
            case .diode, .bjt, .mosfet:
                let nodes = terminalNodes(for: element)
                let voltages = nonlinearState[index] ?? [Double](repeating: 0, count: nodes.count)
                let characteristic = nonlinearCharacteristic(element, terminals: voltages)
                stampNonlinear(
                    nodes: nodes,
                    currents: characteristic.currents,
                    jacobian: characteristic.jacobian,
                    voltages: voltages,
                    incremental: mode.isAC
                )
            }
        }

        for (offset, branch) in branches.enumerated() {
            let k = nodeRows + offset
            if let i = row(branch.element.nodeA) {
                matrix[i][k] = matrix[i][k] + .one
                matrix[k][i] = matrix[k][i] + .one
            }
            if let j = row(branch.element.nodeB) {
                matrix[j][k] = matrix[j][k] - .one
                matrix[k][j] = matrix[k][j] - .one
            }
            rhs[k] = branch.voltage
        }

        let x = try ComplexLinearSolver.solve(matrix, rhs)

        var nodeVoltages = [Complex](repeating: .zero, count: nodeCount)
        for node in 1..<nodeCount {
            nodeVoltages[node] = x[node - 1]
        }

        // Branch currents are only known after the solve, so attach them to the
        // elements that own each branch (voltage sources, plus DC inductor
        // shorts). Passives are computed from the node voltages below.
        var elementCurrents = computeElementCurrents(
            nodeVoltages: nodeVoltages,
            mode: mode,
            nonlinearState: nonlinearState,
            sourceMagnitude: sourceMagnitude,
            sourcePhase: sourcePhase
        )
        var sourceCurrents: [(name: String, current: Complex)] = []
        for (offset, branch) in branches.enumerated() {
            elementCurrents[branch.elementIndex] = x[nodeRows + offset]
            // Only report true voltage sources; DC inductor shorts are internal.
            if branch.element.kind == .voltageSource {
                sourceCurrents.append((branch.element.name, x[nodeRows + offset]))
            }
        }

        return Solution(
            nodeVoltages: nodeVoltages,
            sourceCurrents: sourceCurrents,
            isDC: mode.isDC,
            elementCurrents: elementCurrents
        )
    }

    private func computeElementCurrents(
        nodeVoltages: [Complex],
        mode: AnalysisMode,
        nonlinearState: [Int: [Double]],
        sourceMagnitude: (Element) -> Double,
        sourcePhase: (Element) -> Double
    ) -> [Complex] {
        func voltage(_ node: Int) -> Complex {
            node >= 0 && node < nodeVoltages.count ? nodeVoltages[node] : .zero
        }
        return elements.enumerated().map { index, element in
            let v = voltage(element.nodeA) - voltage(element.nodeB)
            switch element.kind {
            case .resistor:
                return v / Complex(element.value, 0)
            case .capacitor:
                switch mode {
                case .ac(let omega):
                    return v * Complex(0, omega * element.value)
                case .transient(let timestep, _, let capacitorVoltage, _):
                    let conductance = element.value / timestep
                    return v * Complex(conductance, 0) + Complex(-conductance * capacitorVoltage[index], 0)
                case .dc, .operatingPoint:
                    return .zero
                }
            case .inductor:
                switch mode {
                case .ac(let omega):
                    return v / Complex(0, omega * element.value)
                case .transient(let timestep, _, _, let inductorCurrent):
                    let conductance = timestep / element.value
                    return v * Complex(conductance, 0) + Complex(inductorCurrent[index], 0)
                case .dc, .operatingPoint:
                    return .zero
                }
            case .currentSource:
                // The current through an ideal current source is its own value.
                return Complex.fromPolar(
                    magnitude: sourceMagnitude(element),
                    phaseDegrees: sourcePhase(element)
                )
            case .voltageSource:
                // Overwritten in `assemble` from the solved branch current.
                return .zero
            case .diode:
                if mode.isAC {
                    // Small-signal current: g·Δv about the bias point.
                    let bias = nonlinearState[index] ?? [0, 0]
                    let (_, conductance) = diodeCurrentAndConductance(element, voltage: bias[0] - bias[1])
                    return v * Complex(conductance, 0)
                }
                let (current, _) = diodeCurrentAndConductance(element, voltage: v.re)
                return Complex(current, 0)
            case .bjt:
                // Terminal order is [base, collector, emitter]; report the
                // collector current into the device.
                let terminals = terminalNodes(for: element)
                if mode.isAC {
                    let bias = nonlinearState[index] ?? [Double](repeating: 0, count: terminals.count)
                    let characteristic = nonlinearCharacteristic(element, terminals: bias)
                    let solved = terminals.map { voltage($0).re }
                    let current = zip(characteristic.jacobian[1], solved).reduce(0.0) { $0 + $1.0 * $1.1 }
                    return Complex(current, 0)
                }
                let solved = terminals.map { voltage($0).re }
                let characteristic = nonlinearCharacteristic(element, terminals: solved)
                return Complex(characteristic.currents[1], 0)
            case .mosfet:
                // Terminal order is [drain, gate, source, bulk]; report the
                // drain current into the device.
                let terminals = terminalNodes(for: element)
                if mode.isAC {
                    let bias = nonlinearState[index] ?? [Double](repeating: 0, count: terminals.count)
                    let characteristic = nonlinearCharacteristic(element, terminals: bias)
                    let solved = terminals.map { voltage($0).re }
                    let current = zip(characteristic.jacobian[0], solved).reduce(0.0) { $0 + $1.0 * $1.1 }
                    return Complex(current, 0)
                }
                let solved = terminals.map { voltage($0).re }
                let characteristic = nonlinearCharacteristic(element, terminals: solved)
                return Complex(characteristic.currents[0], 0)
            }
        }
    }
}
