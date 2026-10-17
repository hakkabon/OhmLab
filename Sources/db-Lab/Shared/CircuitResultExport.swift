// CircuitResultExport.swift
// Serializes a solved result into a long-format CSV, so an operating point or a
// frequency sweep can be taken into a spreadsheet without retyping it.

import Foundation

enum CircuitResultExport {
    static func csv(_ result: CircuitSimResult) -> String {
        var rows = ["analysis,frequency_hz,signal,quantity,value,time_s,sweep"]

        if let dc = result.dc {
            for node in dc.nodes {
                rows.append(row(analysis: "dc", frequency: nil, signal: node.name, quantity: "voltage", value: node.voltage))
            }
            for component in dc.components {
                rows.append(row(analysis: "dc", frequency: nil, signal: component.name, quantity: "voltage", value: component.voltage))
                rows.append(row(analysis: "dc", frequency: nil, signal: component.name, quantity: "current", value: component.current))
            }
        }

        if let sweep = result.sweep {
            for point in sweep.points {
                let coordinate = point.coordinates
                    .map { "\($0.name)=\(number($0.value))" }
                    .joined(separator: ";")
                for node in point.nodes {
                    rows.append(row(analysis: "sweep", frequency: nil, signal: node.name, quantity: "voltage", value: node.voltage, sweep: coordinate))
                }
                for component in point.components {
                    rows.append(row(analysis: "sweep", frequency: nil, signal: component.name, quantity: "voltage", value: component.voltage, sweep: coordinate))
                    rows.append(row(analysis: "sweep", frequency: nil, signal: component.name, quantity: "current", value: component.current, sweep: coordinate))
                }
            }
        }

        if let ac = result.ac {
            for node in ac.nodes {
                for point in node.response {
                    rows.append(row(analysis: "ac", frequency: point.freqHz, signal: node.name, quantity: "voltage_mag_db", value: point.magnitudeDb))
                    rows.append(row(analysis: "ac", frequency: point.freqHz, signal: node.name, quantity: "voltage_phase_deg", value: point.phaseDeg))
                }
            }
            for component in ac.components {
                for point in component.response {
                    rows.append(row(analysis: "ac", frequency: point.freqHz, signal: component.name, quantity: "current_mag_db", value: point.magnitudeDb))
                    rows.append(row(analysis: "ac", frequency: point.freqHz, signal: component.name, quantity: "current_phase_deg", value: point.phaseDeg))
                }
            }
        }

        if let transient = result.transient {
            for node in transient.nodes {
                for (index, time) in transient.times.enumerated() where index < node.values.count {
                    rows.append(row(analysis: "tran", frequency: nil, signal: node.name, quantity: "voltage", value: node.values[index], time: time))
                }
            }
            for component in transient.components {
                for (index, time) in transient.times.enumerated() where index < component.values.count {
                    rows.append(row(analysis: "tran", frequency: nil, signal: component.name, quantity: "current", value: component.values[index], time: time))
                }
            }
        }

        return rows.joined(separator: "\n")
    }

    private static func row(
        analysis: String,
        frequency: Double?,
        signal: String,
        quantity: String,
        value: Double,
        time: Double? = nil,
        sweep: String? = nil
    ) -> String {
        let frequencyField = frequency.map { number($0) } ?? ""
        let timeField = time.map { number($0) } ?? ""
        let sweepField = sweep.map { escape($0) } ?? ""
        return "\(analysis),\(frequencyField),\(escape(signal)),\(quantity),\(number(value)),\(timeField),\(sweepField)"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
