import SwiftUI

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Circuit name", text: $document.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Spacer()

                Button {
                    Task { await document.runSimulation() }
                } label: {
                    if document.isSimulating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(document.isSimulating)
            }

            Text("SPICE Netlist")
                .font(.headline)

            TextEditor(text: $document.netlistText)
                .font(.system(.body, design: .monospaced))
                .border(Color.gray.opacity(0.4))

            if let error = document.simulationError {
                Text(error)
                    .foregroundStyle(.red)
            } else if let result = document.simulationResult {
                Text("Simulation complete")
                    .font(.headline)
                if let ac = result.ac {
                    Text("AC analysis: \(ac.frequencies.count) frequency points")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle(document.name)
    }
}
