import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Creates or edits a serial console profile.
struct SerialProfileEditorView: View {
    let target: AppState.SerialProfileEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [SerialProfile]

    @State private var name = ""
    @State private var devicePath = ""
    @State private var devices: [SerialDevices.Device] = []
    @State private var baudRate = 115_200
    @State private var customBaud = ""
    @State private var dataBits = 8
    @State private var parity: SerialParity = .none
    @State private var stopBits = 1
    @State private var flowControl: SerialFlowControl = .none
    @State private var sendLineEnding: SerialLineEnding = .cr
    @State private var convertIncomingLF = true
    @State private var localEcho = false
    @State private var hexView = false
    @State private var colorLabel: String?

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var effectiveBaud: Int? {
        if baudRate == -1 {
            guard let value = Int(customBaud.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
            return value
        }
        return baudRate
    }

    private var isValid: Bool {
        !devicePath.trimmingCharacters(in: .whitespaces).isEmpty && effectiveBaud != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Device") {
                    TextField("Name", text: $name, prompt: Text(devicePath.isEmpty ? "Optional" : (devicePath as NSString).lastPathComponent))
                    Picker("Device", selection: $devicePath) {
                        if !devicePath.isEmpty, !devices.contains(where: { $0.path == devicePath }) {
                            Text(devicePath + " (not connected)").tag(devicePath)
                        }
                        Text("Choose…").tag("")
                        ForEach(devices) { device in
                            Text(device.path).tag(device.path)
                        }
                    }
                    HStack {
                        TextField("Or type a path", text: $devicePath, prompt: Text("/dev/cu.usbserial-1420"))
                            .font(.body.monospaced())
                        Button("Refresh") { devices = SerialDevices.list() }
                    }
                    if devices.isEmpty {
                        Text("No /dev/cu.* devices found. Plug in the USB serial adapter; some need a driver from the maker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Colour label") {
                        ColorLabelPicker(selection: $colorLabel)
                    }
                }
                Section("Line settings") {
                    Picker("Baud rate", selection: $baudRate) {
                        ForEach(SerialSettings.commonBaudRates, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                        Text("Other…").tag(-1)
                    }
                    if baudRate == -1 {
                        TextField("Baud rate", text: $customBaud)
                    }
                    Picker("Data bits", selection: $dataBits) {
                        ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Parity", selection: $parity) {
                        ForEach(SerialParity.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Stop bits", selection: $stopBits) {
                        ForEach([1, 2], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Flow control", selection: $flowControl) {
                        ForEach(SerialFlowControl.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Text") {
                    Picker("Return sends", selection: $sendLineEnding) {
                        ForEach(SerialLineEnding.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Convert incoming LF to CR LF", isOn: $convertIncomingLF)
                    Toggle("Local echo", isOn: $localEcho)
                    Toggle("Open in hex view", isOn: $hexView)
                    Text("Hex view shows every byte from the device with an ASCII column; it can be toggled in the status bar while connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .themedForm()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add Console") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
        .onAppear {
            devices = SerialDevices.list()
            load()
        }
    }

    private func load() {
        guard case .edit(let profile) = target else {
            if devicePath.isEmpty, let first = devices.first { devicePath = first.path }
            return
        }
        name = profile.name
        devicePath = profile.devicePath
        if SerialSettings.commonBaudRates.contains(profile.baudRate) {
            baudRate = profile.baudRate
        } else {
            baudRate = -1
            customBaud = String(profile.baudRate)
        }
        dataBits = profile.dataBits
        parity = profile.parity
        stopBits = profile.stopBits
        flowControl = profile.flowControl
        sendLineEnding = profile.sendLineEnding
        convertIncomingLF = profile.convertIncomingLF
        localEcho = profile.localEcho
        hexView = profile.hexView
        colorLabel = profile.colorLabel
    }

    private func save() {
        guard let baud = effectiveBaud else { return }
        let path = devicePath.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? (path as NSString).lastPathComponent : trimmedName
        switch target {
        case .create:
            let profile = SerialProfile(name: finalName, devicePath: path, baudRate: baud, dataBits: dataBits, parity: parity, stopBits: stopBits, flowControl: flowControl, sendLineEnding: sendLineEnding, convertIncomingLF: convertIncomingLF, localEcho: localEcho, hexView: hexView, colorLabel: colorLabel, sortOrder: profiles.count)
            modelContext.insert(profile)
        case .edit(let profile):
            profile.name = finalName
            profile.devicePath = path
            profile.baudRate = baud
            profile.dataBits = dataBits
            profile.parity = parity
            profile.stopBits = stopBits
            profile.flowControl = flowControl
            profile.sendLineEnding = sendLineEnding
            profile.convertIncomingLF = convertIncomingLF
            profile.localEcho = localEcho
            profile.hexView = hexView
            profile.colorLabel = colorLabel
        }
        try? modelContext.save()
        dismiss()
    }
}
