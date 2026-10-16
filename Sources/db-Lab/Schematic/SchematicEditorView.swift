import SwiftUI

struct SchematicEditorView: View {
    @ObservedObject var document: SchematicDocument
    @State private var activeComponentDescriptorID: String?
    @State private var wireToolEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                SchematicCanvasView(
                    document: document,
                    activeComponentDescriptorID: activeComponentDescriptorID,
                    wireToolEnabled: wireToolEnabled
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                inspector
                    .frame(width: 270)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                activeComponentDescriptorID = nil
                wireToolEnabled = false
            } label: {
                Label("Select", systemImage: "cursorarrow")
            }
            .buttonStyle(.bordered)
            .tint(activeComponentDescriptorID == nil && !wireToolEnabled ? .accentColor : .secondary)

            Menu {
                ForEach(ComponentRegistry.shared.allDescriptors.filter { $0.symbol != .ground }, id: \.id) { descriptor in
                    Button(descriptor.displayName) {
                        activeComponentDescriptorID = descriptor.id
                        wireToolEnabled = false
                    }
                }
                Divider()
                Button("Ground") {
                    activeComponentDescriptorID = "ground"
                    wireToolEnabled = false
                }
            } label: {
                Label(
                    activeComponentDescriptorID.flatMap { ComponentRegistry.shared.descriptor(for: $0) }?.displayName ?? "Place Component",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.bordered)
            .tint(activeComponentDescriptorID == nil ? .secondary : .accentColor)

            Button {
                activeComponentDescriptorID = nil
                wireToolEnabled.toggle()
            } label: {
                Label("Wire", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.bordered)
            .tint(wireToolEnabled ? .accentColor : .secondary)

            Spacer()

            Text("\(document.symbols.count) components · \(document.wires.count) wires")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = document.selectedSymbolID,
           let index = document.symbols.firstIndex(where: { $0.id == id }),
           let descriptor = ComponentRegistry.shared.descriptor(for: document.symbols[index].descriptorId) {
            Form {
                Section(descriptor.displayName) {
                    TextField("Reference", text: referenceBinding(at: index))
                    Picker("Rotation", selection: rotationBinding(at: index)) {
                        Text("0°").tag(0)
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                }

                if !descriptor.parameters.isEmpty {
                    Section("Parameters") {
                        ForEach(descriptor.parameters, id: \.id) { parameter in
                            LabeledContent(parameter.name) {
                                HStack(spacing: 4) {
                                    TextField(
                                        parameter.name,
                                        value: parameterBinding(parameter.id, defaultValue: parameter.defaultValue, at: index),
                                        format: .number
                                    )
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 80)
                                    Text(parameter.unit)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Delete Component", role: .destructive) {
                        document.symbols.remove(at: index)
                        document.selectedSymbolID = nil
                        document.rebuildConnectivity()
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Component Selected",
                systemImage: "square.dashed",
                description: Text("Place a component or select one on the canvas to edit its parameters.")
            )
        }
    }

    private func referenceBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { document.symbols[index].refDes },
            set: { document.symbols[index].refDes = $0 }
        )
    }

    private func rotationBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: { document.symbols[index].rotation },
            set: {
                document.symbols[index].rotation = $0
                document.rebuildConnectivity()
            }
        )
    }

    private func parameterBinding(_ key: String, defaultValue: Double, at index: Int) -> Binding<Double> {
        Binding(
            get: { document.symbols[index].parameters[key] ?? defaultValue },
            set: { document.symbols[index].parameters[key] = $0 }
        )
    }
}
