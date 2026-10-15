// DriversPanel.swift
// Panel for adding, editing and removing speaker drivers.

import SwiftUI

struct DriversPanel: View {
    @ObservedObject var document: CrossoverDocument
    @State private var selectedDriverID: UUID?
    @State private var showingAddSheet = false

    var selectedDriver: Binding<DriverModel>? {
        guard let id = selectedDriverID,
              let idx = document.drivers.firstIndex(where: { $0.id == id })
        else { return nil }
        return $document.drivers[idx]
    }

    var body: some View {
        Group {
            #if os(macOS)
        HSplitView {
                driverListPane
                    .frame(minWidth: 180, maxWidth: 240)
                driverEditorPane
            }
            #else
            GeometryReader { geometry in
                let isWide = geometry.size.width >= 600
                let layout = isWide
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    driverListPane
                        .frame(
                            minWidth: isWide ? 180 : 0,
                            maxWidth: isWide ? 240 : .infinity
                        )
                    Divider()
                    driverEditorPane
                }
            }
            #endif
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDriverSheet { role in
                let newDriver: DriverModel
                switch role {
                case .woofer:   newDriver = .defaultWoofer()
                case .tweeter:  newDriver = .defaultTweeter()
                default:
                    var d = DriverModel()
                    d.role = role
                    d.name = role.rawValue
                    newDriver = d
                }
                document.drivers.append(newDriver)
                selectedDriverID = newDriver.id
            }
        }
    }

    private var driverListPane: some View {
        VStack(spacing: 0) {
            driverList
            Divider()
            listToolbar
        }
    }

    @ViewBuilder
    private var driverEditorPane: some View {
        if let binding = selectedDriver {
            DriverEditorView(driver: binding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(binding.wrappedValue.id)
        } else {
            ContentUnavailableView(
                "No Driver Selected",
                systemImage: "speaker.slash",
                description: Text("Select or add a driver to edit its parameters.")
            )
        }
    }

    // MARK: – List

    private var driverList: some View {
        List(selection: $selectedDriverID) {
            ForEach(document.drivers) { driver in
                HStack {
                    Image(systemName: driverIcon(driver.role))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(driver.name).font(.body)
                        Text("\(driver.role.rawValue) · \(String(format: "%.0f", driver.nominalImpedance))Ω · \(String(format: "%.0f", driver.sensitivityDb))dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(driver.id)
                .contextMenu {
                    Button("Duplicate") { duplicateDriver(driver) }
                    Divider()
                    Button("Delete", role: .destructive) { deleteDriver(driver) }
                }
            }
            .onMove { source, dest in
                document.drivers.move(fromOffsets: source, toOffset: dest)
            }
            .onDelete { offsets in
                document.drivers.remove(atOffsets: offsets)
            }
        }
        .listStyle(.inset)
    }

    private var listToolbar: some View {
        HStack {
            Button { showingAddSheet = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)

            Button {
                if let id = selectedDriverID {
                    deleteDriver(withID: id)
                }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .disabled(selectedDriverID == nil)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: – Actions

    private func duplicateDriver(_ driver: DriverModel) {
        var copy = driver
        copy.id = UUID()
        copy.name = driver.name + " Copy"
        document.drivers.append(copy)
        selectedDriverID = copy.id
    }

    private func deleteDriver(_ driver: DriverModel) {
        document.drivers.removeAll { $0.id == driver.id }
        if selectedDriverID == driver.id { selectedDriverID = nil }
    }

    private func deleteDriver(withID id: UUID) {
        document.drivers.removeAll { $0.id == id }
        selectedDriverID = nil
    }

    private func driverIcon(_ role: DriverRoleType) -> String {
        switch role {
        case .woofer, .subwoofer: return "speaker.wave.3"
        case .tweeter, .superTweeter: return "speaker.wave.1"
        default: return "speaker.wave.2"
        }
    }
}

// ─── Add driver sheet ─────────────────────────────────────────────────────────

struct AddDriverSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (DriverRoleType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Driver").font(.title2).bold()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(DriverRoleType.allCases) { role in
                    Button {
                        onAdd(role)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2").font(.title)
                            Text(role.rawValue).font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// ─── Driver editor form ───────────────────────────────────────────────────────

struct DriverEditorView: View {
    @Binding var driver: DriverModel

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Name", text: $driver.name)
                    Picker("Role", selection: $driver.role) {
                        ForEach(DriverRoleType.allCases) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                }

                Section("Electrical Parameters") {
                    LabeledContent("Nominal impedance (Ω)") {
                        DoubleField(value: $driver.nominalImpedance)
                    }
                    LabeledContent("DC resistance Re (Ω)") {
                        DoubleField(value: $driver.re)
                    }
                    LabeledContent("Voice coil inductance Le (H)") {
                        OptionalDoubleField(value: $driver.le, placeholder: "Optional")
                    }
                    LabeledContent("Sensitivity (dB/1W/1m)") {
                        DoubleField(value: $driver.sensitivityDb)
                    }
                    LabeledContent("Power handling (W)") {
                        OptionalDoubleField(value: $driver.powerHandlingW, placeholder: "Optional")
                    }
                    Toggle("Inverted polarity", isOn: $driver.invertedPolarity)
                    LabeledContent("Acoustic offset (mm)") {
                        DoubleField(value: $driver.acousticOffsetMm)
                    }
                }

                Section("Thiele-Small Parameters (optional)") {
                    LabeledContent("Resonance frequency fs (Hz)") {
                        OptionalDoubleField(value: $driver.fs, placeholder: "–")
                    }
                    LabeledContent("Total Qts") {
                        OptionalDoubleField(value: $driver.qts, placeholder: "–")
                    }
                    LabeledContent("Electrical Qes") {
                        OptionalDoubleField(value: $driver.qes, placeholder: "–")
                    }
                    LabeledContent("Mechanical Qms") {
                        OptionalDoubleField(value: $driver.qms, placeholder: "–")
                    }
                    LabeledContent("Equivalent volume Vas (L)") {
                        OptionalDoubleField(value: $driver.vas, placeholder: "–")
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }
}

// ─── Numeric field helpers ────────────────────────────────────────────────────

struct DoubleField: View {
    @Binding var value: Double
    var format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(3))

    var body: some View {
        TextField("", value: $value, format: format)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120)
            .multilineTextAlignment(.trailing)
    }
}

struct OptionalDoubleField: View {
    @Binding var value: Double?
    let placeholder: String
    var format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(3))

    var body: some View {
        TextField(placeholder, value: $value, format: format)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120)
            .multilineTextAlignment(.trailing)
    }
}
