// CircuitResultJSON.swift
// A structured JSON projection of a `CircuitSimResult`, for the headless/batch
// front end (and any other machine consumer) to parse without scrape-y CSV.

import Foundation

public enum CircuitResultJSON {
    public static func encode(_ result: CircuitSimResult, pretty: Bool = true) -> String {
        var root: [String: Any] = ["contractVersion": result.contractVersion]

        if let dc = result.dc {
            root["dc"] = [
                "converged": dc.converged,
                "nodes": dc.nodes.map { ["name": $0.name, "voltage": $0.voltage] },
                "components": dc.components.map {
                    ["name": $0.name, "voltage": $0.voltage, "current": $0.current]
                },
                "sources": dc.sources.map { ["name": $0.name, "current": $0.current] },
            ]
        }

        if let ac = result.ac {
            root["ac"] = [
                "frequencies": ac.frequencies,
                "nodes": ac.nodes.map { signal in
                    ["name": signal.name, "response": signal.response.map(point)]
                },
                "components": ac.components.map { signal in
                    ["name": signal.name, "response": signal.response.map(point)]
                },
            ]
        }

        if let transient = result.transient {
            root["transient"] = [
                "times": transient.times,
                "nodes": transient.nodes.map { ["name": $0.name, "values": $0.values] },
                "components": transient.components.map { ["name": $0.name, "values": $0.values] },
            ]
        }

        if let sweep = result.sweep {
            root["sweep"] = [
                "axes": sweep.axes.map { ["name": $0.name, "values": $0.values] },
                "points": sweep.points.map { point in
                    [
                        "coordinates": point.coordinates.map { ["name": $0.name, "value": $0.value] },
                        "nodes": point.nodes.map { ["name": $0.name, "voltage": $0.voltage] },
                        "components": point.components.map {
                            ["name": $0.name, "voltage": $0.voltage, "current": $0.current]
                        },
                    ]
                },
            ]
        }

        if !result.fourier.isEmpty {
            root["fourier"] = result.fourier.map { entry -> [String: Any] in
                let spectrum = entry.spectrum
                return [
                    "variable": entry.variable,
                    "fundamentalFrequency": entry.fundamentalFrequency,
                    "dcComponent": spectrum.dcComponent,
                    "totalHarmonicDistortion": spectrum.totalHarmonicDistortion,
                    "harmonics": spectrum.harmonics.map { harmonic in
                        [
                            "frequency": harmonic.frequency,
                            "magnitude": harmonic.magnitude,
                            "normalizedMagnitude": harmonic.normalizedMagnitude,
                            "phaseDegrees": harmonic.phaseDegrees,
                            "normalizedPhaseDegrees": harmonic.normalizedPhaseDegrees,
                        ]
                    },
                ]
            }
        }

        root["warnings"] = result.warnings

        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func point(_ freqPoint: FreqPoint) -> [String: Any] {
        [
            "freqHz": freqPoint.freqHz,
            "magnitudeDb": freqPoint.magnitudeDb,
            "phaseDeg": freqPoint.phaseDeg,
        ]
    }
}
