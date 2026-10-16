import SwiftUI

struct SchematicEditorView: View {
    enum Tool {
        case select, wire, label
    }

    @ObservedObject var document: SchematicDocument
    @State private var activeComponentDescriptorID: String?
    @State private var tool: Tool = .select
    @State private var pendingLabelName = "NET"
    @State private var referenceDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                SchematicCanvasView(
                    document: document,
                    activeComponentDescriptorID: activeComponentDescriptorID,
                    wireToolEnabled: tool == .wire,
                    labelToolEnabled: tool == .label,
                    pendingLabelName: pendingLabelName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                inspector
                    .frame(width: 280)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                activeComponentDescriptorID = nil
                tool = .select
            } label: {
                Label("Select", systemImage: "cursorarrow")
            }
            .buttonStyle(.bordered)
            .tint(tool == .select && activeComponentDescriptorID == nil ? .accentColor : .secondary)

            Menu {
                ForEach(ComponentRegistry.shared.allDescriptors.filter { $0.symbol != .ground }, id: \.id) { descriptor in
                    Button(descriptor.displayName) {
                        activeComponentDescriptorID = descriptor.id
                        tool = .select
                    }
                }
                Divider()
                Button("Ground") {
                    activeComponentDescriptorID = "ground"
                    tool = .select
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
                tool = tool == .wire ? .select : .wire
            } label: {
                Label("Wire", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.bordered)
            .tint(tool == .wire ? .accentColor : .secondary)

            Button {
                activeComponentDescriptorID = nil
                tool = tool == .label ? .select : .label
            } label: {
                Label("Label", systemImage: "tag")
            }
            .buttonStyle(.bordered)
            .tint(tool == .label ? .accentColor : .secondary)

            if tool == .label {
                TextField("Net name", text: $pendingLabelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            Divider().frame(height: 20)

            Button {
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(!document.canUndo)
            .help("Undo")

            Button {
                document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .disabled(!document.canRedo)
            .help("Redo")

            Button {
                document.rotateSelection(by: 90)
            } label: {
                Image(systemName: "rotate.right")
            }
            .buttonStyle(.bordered)
            .disabled(document.selectedSymbolID == nil)
            .help("Rotate (R)")

            Button(role: .destructive) {
                document.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(document.selectedSymbolID == nil && document.selectedWireID == nil && document.selectedLabelID == nil)
            .help("Delete")

            Spacer()

            Text("\(document.symbols.count) components · \(document.wires.count) wires · \(document.netLabels.count) labels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = document.selectedSymbolID,
           let symbol = document.symbols.first(where: { $0.id == id }),
           let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) {
            symbolInspector(symbol: symbol, descriptor: descriptor)
        } else if let id = document.selectedWireID,
                  let wire = document.wires.first(where: { $0.id == id }) {
            Form {
                Section("Wire") {
                    Text("\(wire.points.count) points")
                    Button("Delete Wire", role: .destructive) { document.deleteWire(id: id) }
                }
            }
            .formStyle(.grouped)
        } else if let id = document.selectedLabelID,
                  let label = document.netLabels.first(where: { $0.id == id }) {
            Form {
                Section("Net Label") {
                    TextField("Name", text: labelNameBinding(id: id, current: label.name))
                    Button("Delete Label", role: .destructive) { document.deleteNetLabel(id: id) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "square.dashed",
                description: Text("Place a component or select one on the canvas to edit its values.")
            )
        }
    }

    private func symbolInspector(symbol: SymbolInstance, descriptor: ComponentDescriptor) -> some View {
        Form {
            Section(descriptor.displayName) {
                TextField("Reference", text: $referenceDraft)
                    .onSubmit { document.setReference(id: symbol.id, to: referenceDraft) }
                Picker("Rotation", selection: rotationBinding(id: symbol.id, current: symbol.rotation)) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
            }
            .onAppear { referenceDraft = symbol.refDes }
            .onChange(of: document.selectedSymbolID) { _, _ in referenceDraft = symbol.refDes }

            if !descriptor.parameters.isEmpty {
                Section("Parameters") {
                    ForEach(descriptor.parameters, id: \.id) { parameter in
                        LabeledContent(parameter.name) {
                            HStack(spacing: 4) {
                                TextField(
                                    parameter.name,
                                    value: parameterBinding(
                                        parameter.id,
                                        defaultValue: parameter.defaultValue,
                                        symbolID: symbol.id,
                                        current: symbol.parameters[parameter.id]
                                    ),
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
                    document.deleteSymbol(id: symbol.id)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func rotationBinding(id: UUID, current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { document.setRotation(id: id, to: $0) }
        )
    }

    private func parameterBinding(_ key: String, defaultValue: Double, symbolID: UUID, current: Double?) -> Binding<Double> {
        Binding(
            get: { current ?? defaultValue },
            set: { document.setParameter(id: symbolID, key: key, value: $0) }
        )
    }

    private func labelNameBinding(id: UUID, current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { document.renameNetLabel(id: id, to: $0) }
        )
    }
}

private extension SchematicDocument {
    func rotateSelection(by degrees: Int) {
        guard let id = selectedSymbolID else { return }
        rotateSymbol(id: id, by: degrees)
    }
}
