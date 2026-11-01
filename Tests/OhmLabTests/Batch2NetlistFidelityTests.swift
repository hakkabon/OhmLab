// Batch2NetlistFidelityTests.swift
// Regression tests for the second review batch: SPICE continuation lines,
// `.tran` UIC/tmax, and `.lib <file> <section>` selection.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("Batch 2 netlist fidelity")
struct Batch2NetlistFidelityTests {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private func fixture(_ name: String, extension ext: String) throws -> String {
        try String(
            contentsOf: fixturesDirectory.appendingPathComponent("\(name).\(ext)"),
            encoding: .utf8
        )
    }

    /// Imports the fixture library so its directory becomes a search path for
    /// the netlist's `.lib` card when solving through the engine façade.
    private func fixtureLibrary() throws -> SpiceModelLibrary {
        let url = fixturesDirectory.appendingPathComponent("kicad_models.lib")
        return try SpiceModelLibrary.parse(
            try String(contentsOf: url, encoding: .utf8),
            name: "kicad_models",
            sourcePath: url.path
        )
    }

    // MARK: - Continuation lines

    @Test func foldContinuationsKeepsLineNumbers() {
        let folded = SpiceNetlistParser.foldContinuations(
            "R1 1 2\n+ 1k\nR2 2 0 2k"
        )
        let lines = folded.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "R1 1 2 1k")
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "R2 2 0 2k")
    }

    @Test func kicadFixtureFoldsElementAndSourceContinuations() throws {
        let parsed = try KiCadInterchange.parseNetlist(
            try fixture("kicad_rc_export", extension: "cir"),
            include: KiCadInterchange.fileIncludeResolver(relativeTo: fixturesDirectory)
        )

        let resistor = try #require(parsed.circuit.elements.first { $0.name == "R1" })
        #expect(abs(resistor.value - 1_000) < 1e-9)

        let capacitor = try #require(parsed.circuit.elements.first { $0.name == "C1" })
        #expect(abs(capacitor.value - 1e-6) < 1e-18)

        let source = try #require(parsed.circuit.elements.first { $0.name == "V1" })
        let waveform = try #require(source.transient)
        #expect(abs(waveform.value(at: 0)) < 1e-12)
        // Delay 0, rise 1 ns, pulse width 1 µs, period 2 µs.
        #expect(abs(waveform.value(at: 0.5e-9) - 2.5) < 1e-9)
        #expect(abs(waveform.value(at: 1.5e-9) - 5) < 1e-9)
        #expect(abs(waveform.value(at: 1.0015e-6) - 2.5) < 1e-6)
        #expect(abs(waveform.value(at: 2e-6)) < 1e-9)
    }

    // MARK: - .lib sections

    @Test func libCardLoadsOnlyTheRequestedSection() throws {
        let parsed = try KiCadInterchange.parseNetlist(
            try fixture("kicad_rc_export", extension: "cir"),
            include: KiCadInterchange.fileIncludeResolver(relativeTo: fixturesDirectory)
        )
        let diode = try #require(parsed.circuit.elements.first { $0.name == "D1" })
        // "Diodes" uses IS=2e-14; the later "Alternate" section uses IS=9e-9.
        // Loading the whole file would let the later model win.
        #expect(abs((diode.diode?.saturationCurrent ?? 0) - 2e-14) < 1e-20)
    }

    @Test func libCardWarnsWhenSectionIsMissing() throws {
        let library = """
        .lib Diodes
        .model DMOD D(IS=2e-14)
        .endl
        """
        let resolver: SpiceIncludeResolver = { path in
            path == "models.lib" ? library : nil
        }
        let netlist = """
        V1 in 0 5
        R1 in out 1k
        D1 out 0 DMOD
        .lib "models.lib" "Missing"
        .end
        """
        #expect(throws: SpiceParseError.self) {
            _ = try SpiceNetlistParser.parse(netlist, include: resolver)
        }
    }

    // MARK: - .tran tmax

    @Test func tranCardParsesTmaxAndUIC() throws {
        let withBoth = try SpiceNetlistParser.parse(
            "V1 1 0 1\nR1 1 0 1k\n.tran 1u 100u 0 10n UIC\n.end"
        )
        #expect(withBoth.analysis.tranStep == 1e-6)
        #expect(abs(withBoth.analysis.tranStop - 100e-6) < 1e-15)
        #expect(withBoth.analysis.tranMaxStep == 10e-9)
        #expect(withBoth.analysis.tranUseInitialConditions)

        let uicFirst = try SpiceNetlistParser.parse(
            "V1 1 0 1\nR1 1 0 1k\n.tran 1u 100u UIC\n.end"
        )
        #expect(uicFirst.analysis.tranUseInitialConditions)
        #expect(uicFirst.analysis.tranMaxStep == nil)
        #expect(uicFirst.analysis.tranStart == 0)

        let noFlags = try SpiceNetlistParser.parse(
            "V1 1 0 1\nR1 1 0 1k\n.tran 1u 100u\n.end"
        )
        #expect(!noFlags.analysis.tranUseInitialConditions)
        #expect(noFlags.analysis.tranMaxStep == nil)
    }

    @Test func tranCardRejectsNonPositiveTmax() {
        #expect(throws: SpiceParseError.self) {
            _ = try SpiceNetlistParser.parse(
                "V1 1 0 1\nR1 1 0 1k\n.tran 1u 100u 0 0\n.end"
            )
        }
    }

    @Test func tmaxClampsTheNativeTransientStep() throws {
        let netlist = """
        V1 in 0 PULSE(0 5 0 1n 1n 1 2)
        R1 in out 1k
        C1 out 0 1u
        .tran 1u 10u 0 100n
        .end
        """
        let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
        let transient = try #require(result.transient)
        // 10 µs at 100 ns steps, plus the initial sample.
        #expect(transient.times.count == 101)
        #expect(abs((transient.times[1] - transient.times[0]) - 100e-9) < 1e-18)
        #expect(abs((transient.times.last ?? 0) - 10e-6) < 1e-15)
    }

    @Test func kicadFixtureRunsWithTheClampedStep() throws {
        let text = try fixture("kicad_rc_export", extension: "cir")
        let result = try SimulationEngine.solve(
            netlist: text,
            settings: .default,
            libraries: [try fixtureLibrary()]
        )
        let transient = try #require(result.transient)
        // 100 µs at 10 ns steps, plus the initial sample.
        #expect(transient.times.count == 10_001)
        #expect(abs((transient.times[1] - transient.times[0]) - 10e-9) < 1e-18)
    }

    // MARK: - .tran UIC

    @Test func uicStartsFromZeroInsteadOfTheOperatingPoint() throws {
        let netlist = """
        V1 in 0 DC 5
        R1 in out 1k
        C1 out 0 1u
        .tran 1u 5u UIC
        .end
        """
        let withUIC = try SimulationEngine.solve(netlist: netlist, settings: .default)
        let withoutUIC = try SimulationEngine.solve(
            netlist: netlist.replacingOccurrences(of: " UIC", with: ""),
            settings: .default
        )

        let uicOut = try #require(withUIC.transient?.nodes.first { $0.name == "out" })
        let dcOut = try #require(withoutUIC.transient?.nodes.first { $0.name == "out" })

        // Without UIC the capacitor is pre-charged to the 5 V operating point.
        #expect(abs(dcOut.values[0] - 5) < 1e-9)
        // With UIC every node starts at zero and then charges through R1.
        #expect(abs(uicOut.values[0]) < 1e-12)
        #expect(uicOut.values[1] > 0)
        #expect(uicOut.values[1] < 5)
    }
}
