import SwiftUI

struct SchematicEditorView: View {
    enum Tool {
        case select, wire, bus, label
    }

    @ObservedObject var document: SchematicDocument
    @State private var activeComponentDescriptorID: String?
    @State private var pendingSubcircuitSheetId: UUID?
    @State private var tool: Tool = .select
    @State private var pendingLabelName = "NET"
    @State private var referenceDraft = ""
    @State private var newPortName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            sheetNavigationBar
            Divider()
            HStack(spacing: 0) {
                SchematicCanvasView(
                    document: document,
                    activeComponentDescriptorID: activeComponentDescriptorID,
                    wireToolEnabled: tool == .wire,
                    busToolEnabled: tool == .bus,
                    labelToolEnabled: tool == .label,
                    pendingLabelName: pendingLabelName,
                    pendingSubcircuitSheetId: pendingSubcircuitSheetId
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(document.activeSheetId)

                Divider()

                inspector
                    .frame(width: 280)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                clearTools()
            } label: {
                Label("Select", systemImage: "cursorarrow")
            }
            .buttonStyle(.bordered)
            .tint(tool == .select && activeComponentDescriptorID == nil && pendingSubcircuitSheetId == nil ? .accentColor : .secondary)

            Menu {
                ForEach(ComponentRegistry.shared.allDescriptors.filter { $0.symbol != .ground && $0.symbol != .subcircuit }, id: \.id) { descriptor in
                    Button(descriptor.displayName) {
                        clearTools()
                        activeComponentDescriptorID = descriptor.id
                    }
                }
                Divider()
                Button("Ground") {
                    clearTools()
                    activeComponentDescriptorID = "ground"
                }
            } label: {
                Label(
                    activeComponentDescriptorID.flatMap { ComponentRegistry.shared.descriptor(for: $0) }?.displayName ?? "Place Component",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.bordered)
            .tint(activeComponentDescriptorID == nil ? .secondary : .accentColor)

            subcircuitMenu

            Button {
                clearTools()
                tool = .wire
            } label: {
                Label("Wire", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.bordered)
            .tint(tool == .wire ? .accentColor : .secondary)

            Button {
                clearTools()
                tool = .bus
            } label: {
                Label("Bus", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
            }
            .buttonStyle(.bordered)
            .tint(tool == .bus ? .accentColor : .secondary)

            Button {
                clearTools()
                tool = .label
            } label: {
                Label("Label", systemImage: "tag")
            }
            .buttonStyle(.bordered)
            .tint(tool == .label ? .accentColor : .secondary)

            if tool == .label {
                TextField("Net name", text: $pendingLabelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
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

    private func clearTools() {
        activeComponentDescriptorID = nil
        pendingSubcircuitSheetId = nil
        tool = .select
    }

    private var subcircuitMenu: some View {
        Menu {
            Button {
                clearTools()
                let sheet = document.addSheet()
                pendingSubcircuitSheetId = sheet.id
            } label: {
                Label("New Subcircuit", systemImage: "square.on.square.dashed")
            }
            if document.sheets.count > 1 {
                Divider()
                ForEach(document.sheets.dropFirst()) { sheet in
                    Button(sheet.name) {
                        clearTools()
                        pendingSubcircuitSheetId = sheet.id
                    }
                }
            }
        } label: {
            Label(pendingSubcircuitSheetId == nil ? "Subcircuit" : "Placing Subcircuit", systemImage: "square.on.square")
        }
        .buttonStyle(.bordered)
        .tint(pendingSubcircuitSheetId == nil ? .secondary : .accentColor)
    }

    private var sheetNavigationBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            ForEach(Array(document.hierarchyPath.enumerated()), id: \.element.id) { index, sheet in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(sheet.name) {
                    document.enterSheet(id: sheet.id)
                }
                .buttonStyle(.plain)
                .fontWeight(sheet.id == document.activeSheetId ? .semibold : .regular)
                .foregroundStyle(sheet.id == document.activeSheetId ? Color.accentColor : .primary)
                .disabled(sheet.id == document.activeSheetId)
            }
            Spacer()
            if !document.isAtRoot {
                Button {
                    document.goToParentSheet()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = document.selectedSymbolID,
           let symbol = document.symbols.first(where: { $0.id == id }),
           let descriptor = document.subcircuitCatalog.descriptor(for: symbol) {
            symbolInspector(symbol: symbol, descriptor: descriptor)
        } else if let id = document.selectedWireID,
                  let wire = document.wires.first(where: { $0.id == id }) {
            Form {
                Section("Wire") {
                    Text(wire.isBus ? "Bus · \(wire.points.count) points" : "\(wire.points.count) points")
                    Button("Delete Wire", role: .destructive) { document.deleteWire(id: id) }
                }
            }
            .formStyle(.grouped)
        } else if let id = document.selectedLabelID,
                  let label = document.netLabels.first(where: { $0.id == id }) {
            Form {
                Section("Net Label") {
                    TextField("Name", text: labelNameBinding(id: id, current: label.name))
                    if let bus = label.busName, bus.isDeclaration {
                        Text("Bus with \(bus.members.count) members")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete Label", role: .destructive) { document.deleteNetLabel(id: id) }
                }
            }
            .formStyle(.grouped)
        } else {
            sheetInspector
        }
    }

    private var sheetInspector: some View {
        Form {
            Section("Sheet") {
                TextField(
                    "Name",
                    text: Binding(
                        get: { document.activeSheet.name },
                        set: { document.renameSheet(id: document.activeSheetId, to: $0) }
                    )
                )
                if !document.isAtRoot {
                    Button {
                        document.goToParentSheet()
                    } label: {
                        Label("Go to Parent", systemImage: "arrow.up")
                    }
                }
            }

            Section("Ports") {
                ForEach(document.activeSheet.ports) { port in
                    HStack {
                        Text(port.name)
                        Spacer()
                        Picker("", selection: portDirectionBinding(portId: port.id, current: port.isInput)) {
                            Text("In").tag(true)
                            Text("Out").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 90)
                        Button(role: .destructive) {
                            document.removeSheetPort(sheetId: document.activeSheetId, portId: port.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New port", text: $newPortName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        document.addSheetPort(sheetId: document.activeSheetId, name: newPortName)
                        newPortName = ""
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(newPortName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A port binds to the same-named net label inside this sheet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if document.sheets.count > 1 {
                Section("Hierarchy") {
                    ForEach(document.sheets) { sheet in
                        HStack {
                            Text(sheet.name)
                            Spacer()
                            if sheet.id == document.activeSheetId {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Enter") { document.enterSheet(id: sheet.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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

            if symbol.isSubcircuitInstance, let reference = symbol.sheetRef, let sheet = document.sheet(id: reference) {
                Section("Subcircuit") {
                    Text(sheet.name)
                    Text("\(sheet.ports.count) port\(sheet.ports.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        document.enterSheet(id: reference)
                    } label: {
                        Label("Enter Subcircuit", systemImage: "arrow.down.right.circle")
                    }
                }
            }

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

    private func portDirectionBinding(portId: UUID, current: Bool) -> Binding<Bool> {
        Binding(
            get: { current },
            set: { document.setSheetPortInput(sheetId: document.activeSheetId, portId: portId, isInput: $0) }
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
