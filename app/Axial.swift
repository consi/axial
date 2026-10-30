import SwiftUI
import AppKit
import ServiceManagement

struct ButtonAction: Codable, Equatable {
    var keyCode: Int? = nil
    var modifiers: UInt64? = nil
    var command: String? = nil
    var action: String? = nil
    var label: String? = nil
}
struct Profile: Codable, Equatable {
    var gain: [Double] = Array(repeating: 1, count: 6)
    var deadzone: [Double] = Array(repeating: 0, count: 6)
    var invert: [Bool] = Array(repeating: false, count: 6)
    var dominant = false
    var translation = true
    var rotation = true
    var orbit = true
    var led = true
    var buttons: [ButtonAction] = Array(repeating: ButtonAction(), count: 32)
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gain = try c.decodeIfPresent([Double].self, forKey: .gain) ?? gain
        deadzone = try c.decodeIfPresent([Double].self, forKey: .deadzone) ?? deadzone
        invert = try c.decodeIfPresent([Bool].self, forKey: .invert) ?? invert
        dominant = try c.decodeIfPresent(Bool.self, forKey: .dominant) ?? dominant
        translation = try c.decodeIfPresent(Bool.self, forKey: .translation) ?? translation
        rotation = try c.decodeIfPresent(Bool.self, forKey: .rotation) ?? rotation
        orbit = try c.decodeIfPresent(Bool.self, forKey: .orbit) ?? orbit
        led = try c.decodeIfPresent(Bool.self, forKey: .led) ?? led
        buttons = try c.decodeIfPresent([ButtonAction].self, forKey: .buttons) ?? buttons
        buttons += Array(repeating: ButtonAction(), count: max(0, 32 - buttons.count))
        guard gain.count == 6, deadzone.count == 6, invert.count == 6, buttons.count == 32 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid profile dimensions"))
        }
    }
}
struct WebConfiguration: Codable {
    var enabled = true
}
struct WebStatus: Codable {var enabled: Bool;var listening: Bool;var connections: Int;var error: String}
struct Configuration: Codable {var version = 1; var profiles = ["*": Profile()];var web: WebConfiguration? = nil}
struct Device: Codable, Identifiable {
    var id: Int; var vendor: Int; var product: Int; var name: String
    var axes: [Int]; var buttons: UInt32
    var ledSupported: Bool?; var ledState: Int?; var ledError: UInt32?
    // Hardware zero calibration: supported, running now, done since connecting.
    var rezero: Bool?; var calibrating: Bool?; var deviceCalibrated: Bool?
    var layout: ControllerLayout? {DeviceCatalog.identity(vendor: vendor, product: product).flatMap {DeviceCatalog.layouts[$0]}}
    var displayName: String {layout?.name ?? name}
}
struct Status: Codable {
    var web: WebStatus? = nil
    var devices: [Device]; var clients: Int; var reports: UInt64; var overflows: UInt64
    var rejected: UInt64; var foregroundApp: String; var accessibility: Bool; var mock: Bool
    var connectedClients: Int {clients + (web?.connections ?? 0)}
}
struct AppCommand: Codable, Identifiable {var id: String; var label: String}

@MainActor final class Model: ObservableObject {
    let webSetup = WebSetupCoordinator(operations: NativeWebSetup(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers/axial-web-setup")))
    @Published var status: Status?
    @Published var config = Configuration()
    @Published var selected = "*"
    @Published var message = "Connecting to Axial…"
    @Published var commands: [String: [AppCommand]] = [:]
    @Published private(set) var configurationReady = false
    @Published var launchAtLogin = false
    @Published var selectedDevice: Int?
    @Published var tab = 0
    @Published var recording: Int?
    @Published var buttonLog: [ButtonEntry] = []
    @Published var lostButtonLogs: UInt64 = 0
    @Published var buttonLogError: String?
    @Published var diagnostics = DiagnosticHistory()
    lazy var testRenderer = TestRenderer()
    lazy var testSceneView = TestSceneView(frame: TestSceneView.placeholderFrame)
    private var nextLogID: UInt64 = 0
    private let client: any ServiceRequesting
    private var log: SessionLog?
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let launcher: (any ServiceLaunching)?
    private var lastServiceStart: UInt64 = 0
    private var quitting = false
    private var loaded = false
    private var ownsPreview = false
    private var stopped = false
    private var editRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var saveInFlight = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var appNames: [String: String] = [:]
    var hasUnsavedChanges: Bool {editRevision != savedRevision}

    init(live: Bool = true, client: any ServiceRequesting = ServiceClient(), launcher: (any ServiceLaunching)? = nil) {
        self.client = client
        self.launcher = launcher ?? (live ? NativeServiceLauncher() : nil)
        guard live else {configurationReady = true;return}
        previewStart();ownsPreview = true
        do {
            log = try SessionLog(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Axial", isDirectory: true))
        } catch {buttonLogError = "Could not create button log: \(error.localizedDescription)"}
        // Migrate the previous always-running agent to app-owned service lifetime.
        // Keep its login preference, but remove KeepAlive so Quit really stops input.
        let oldService = SMAppService.agent(plistName: "pro.jest.service.plist")
        do {
            if oldService.status == .enabled || oldService.status == .requiresApproval {
                if oldService.status == .enabled && SMAppService.mainApp.status == .notRegistered {try SMAppService.mainApp.register()}
                try oldService.unregister()
            }
        } catch {message = "Could not update service startup: \(error.localizedDescription)"}
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startPolling()
    }
    func startPolling() {
        guard pollTask == nil, !stopped else {return}
        let client = self.client
        pollTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                let data = await client.request("{\"op\":\"status\"}")
                guard !Task.isCancelled else {break}
                self?.acceptStatus(data)
                if self?.status != nil && self?.launcher?.isRunning == false {
                    // Replace a helper left by an older installation with our child.
                    // Wait for a disconnected poll before starting, so HID is released.
                    _ = await client.request("{\"op\":\"stop\"}")
                    guard !Task.isCancelled else {break}
                    self?.acceptStatus(Data())
                } else if self?.status == nil {self?.ensureServiceRunning()}
                if self?.status != nil {
                    if self?.loaded == false {await self?.load()}
                    if self?.hasUnsavedChanges == true {await self?.save()}
                    if count % 3 == 0 {await self?.loadCommands()}
                    if count % 5 == 0 {await self?.refreshWebSetup()}
                }
                count += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshPreview()
                self?.collectButtonLog()
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }
    func acceptStatus(_ data: Data) {
        guard !stopped else {return}
        if let newStatus = try? JSONDecoder().decode(Status.self, from: data) {
            let previousDevice = device
            status = newStatus
            let now = previewNow()
            diagnostics.record(time: Double(now) / 1_000_000_000, wall: Date(), reports: newStatus.reports, clients: newStatus.connectedClients, overflows: newStatus.overflows, ignored: newStatus.rejected)
            if !newStatus.devices.contains(where: {$0.id == selectedDevice}) {selectedDevice = newStatus.devices.first?.id}
            if previousDevice?.id != device?.id || previousDevice?.vendor != device?.vendor || previousDevice?.product != device?.product {recording = nil}
        } else {
            if status != nil {diagnostics.disconnect()}
            status = nil;loaded = false;recording = nil
            message = "Connecting to Axial…"
        }
    }
    private func refreshPreview() {
        // Only the Motion and Buttons panes display these values. Publishing a
        // whole Status on every report needlessly invalidates the settings tree
        // during CAD navigation and the independently driven SceneKit preview.
        guard tab == 0 || tab == 1, let application = NSApp, !application.isHidden,
              application.windows.contains(where: {$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)}) else {return}
        guard var next = status, let id = selectedDevice, let index = next.devices.firstIndex(where: {$0.id == id}) else {return}
        var axes = [Double](repeating: 0, count: 6);var buttons: UInt32 = 0
        guard previewRead(UInt32(id), &axes, &buttons) else {return}
        let values = axes.map(Int.init)
        if (tab == 0 && next.devices[index].axes != values) || next.devices[index].buttons != buttons {
            next.devices[index].axes = values;next.devices[index].buttons = buttons;status = next
        }
    }
    func shutdown() {
        guard !stopped else {return};stopped = true
        pollTask?.cancel();previewTask?.cancel();saveTask?.cancel()
        if ownsPreview {previewStop();ownsPreview = false}
        collectButtonLog(limit: 4096);log?.flush()
    }
    deinit {
        pollTask?.cancel();previewTask?.cancel();saveTask?.cancel()
        if ownsPreview {previewStop()}
    }
    func collectButtonLog(limit: Int = 256) {
        var timestamp: UInt64 = 0;var device: UInt32 = 0;var changed: UInt32 = 0;var buttons: UInt32 = 0;var reason: UInt32 = 0;var identity: UInt32 = 0
        var entries: [ButtonEntry] = [];var csv = ""
        let wall = Date();let monotonic = previewNow()
        // Bound main-actor work even when a producer continuously fills the ring.
        for _ in 0..<limit {
            guard previewPopLog(&timestamp, &device, &changed, &buttons, &reason, &identity) else {break}
            let date = wall.addingTimeInterval((Double(timestamp) - Double(monotonic)) / 1_000_000_000)
            for index in 0..<32 where changed & (1 << index) != 0 {
                nextLogID += 1;let pressed = buttons & (1 << index) != 0;let reset = reason != 3
                let entry = ButtonEntry(id: nextLogID, time: date, device: device, button: index + 1, pressed: pressed, reset: reset, identity: identity)
                entries.append(entry);csv += entry.csvRow
            }
        }
        if !entries.isEmpty {buttonLog.append(contentsOf: entries);if buttonLog.count > 2000 {buttonLog.removeFirst(buttonLog.count - 2000)}}
        if !csv.isEmpty {log?.append(Data(csv.utf8))}
        if let error = log?.error {buttonLogError = error}
        let lost = previewLostLogs()
        if lostButtonLogs != lost {lostButtonLogs = lost}
    }
    func clearButtonLog() {buttonLog.removeAll()}
    func exportButtonLog() {
        collectButtonLog()
        let panel = NSSavePanel();panel.nameFieldStringValue = "Axial-buttons.csv"
        if panel.runModal() == .OK, let destination = panel.url, let log {
            Task { [weak self] in
                do {try await log.export(to: destination)}
                catch {self?.message = "Could not export button log: \(error.localizedDescription)"}
            }
        }
    }
    var device: Device? {status?.devices.first(where: {$0.id == selectedDevice}) ?? status?.devices.first}
    var profile: Profile {config.profiles[selected] ?? config.profiles["*"] ?? Profile()}
    func edit(_ change: (inout Profile) -> Void) {
        guard configurationReady else {return}
        var p = profile; change(&p); config.profiles[selected] = p;editRevision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {try await Task.sleep(nanoseconds: 250_000_000)} catch {return}
            await self?.save()
        }
    }
    func load() async {
        let revision = editRevision
        let data = await client.request("{\"op\":\"getConfig\"}")
        guard !stopped, let value = try? JSONDecoder().decode(Configuration.self, from: data) else {return}
        loaded = true;configurationReady = true
        if editRevision == revision && !hasUnsavedChanges {
            config = value;message = ""
            if config.profiles[selected] == nil {selected = "*"}
        }
    }
    func loadCommands() async {
        let data = await client.request("{\"op\":\"getCommands\"}")
        if !stopped, let value = try? JSONDecoder().decode([String: [AppCommand]].self, from: data) {commands = value}
    }
    func editWeb(_ change: (inout WebConfiguration) -> Void) {
        guard configurationReady else {return}
        var web = config.web ?? WebConfiguration();change(&web);config.web = web;editRevision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else {return};await self?.save()
        }
    }
    func refreshWebSetup() async {
        guard status?.mock == false, configurationReady else {return}
        let client = self.client
        await webSetup.refresh(enabled: config.web?.enabled ?? true, listening: status?.web?.listening ?? false, listenerError: status?.web?.error ?? "") {
            _ = await client.request("{\"op\":\"retryWeb\"}")
        }
    }
    func setUpWeb() async {
        guard status?.mock == false, !stopped, config.web?.enabled != false else {return}
        let client = self.client
        let window = NSApp.keyWindow ?? (NSApp.delegate as? AxialAppDelegate)?.settingsWindow
        await webSetup.setUp(restoreWindow: { [weak self, weak window] in
            guard self?.quitting == false, self?.stopped == false else {return}
            window?.deminiaturize(nil);window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }) { [weak self] in
            guard self?.quitting == false, self?.stopped == false else {return}
            _ = await client.request("{\"op\":\"retryWeb\"}")
        }
    }
    func save() async {
        guard !stopped, configurationReady else {return}
        if saveInFlight {
            await withCheckedContinuation {saveWaiters.append($0)}
            return
        }
        saveInFlight = true
        defer {saveInFlight = false;let waiters = saveWaiters;saveWaiters.removeAll();for waiter in waiters {waiter.resume()}}
        repeat {
            let revision = editRevision
            guard let encoded = try? JSONEncoder().encode(config), let json = String(data: encoded, encoding: .utf8) else {message = "Could not encode settings.";return}
            let data = await client.request("{\"op\":\"setConfig\",\"config\":\(json)}")
            let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let saved = response?["ok"] as? Bool == true
            if saved {savedRevision = revision}
            if revision == editRevision {
                message = saved ? "" : (response?["error"] as? String ?? "Could not save settings: the service did not respond.")
                return
            }
            // Edits that arrive while a request is in flight are committed next.
        } while !stopped
    }
    private func ensureServiceRunning() {
        guard !quitting, !stopped, let launcher, !launcher.isRunning else {return}
        let now = previewNow()
        guard lastServiceStart == 0 || now - lastServiceStart >= 3_000_000_000 else {return}
        lastServiceStart = now
        do {try launcher.start();message = "Starting service…"}
        catch {message = "Could not start service: \(error.localizedDescription)"}
    }
    func prepareToQuit() async {
        guard !quitting else {return};quitting = true
        pollTask?.cancel();previewTask?.cancel();saveTask?.cancel()
        if hasUnsavedChanges {await save()}
        _ = await client.request("{\"op\":\"stop\"}")
        launcher?.terminate()
        // Wait for an owned helper to release HID and held keys before exiting.
        let deadline = previewNow() + 3_000_000_000
        while launcher?.isRunning == true && previewNow() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        shutdown()
    }
    func login(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {try SMAppService.mainApp.register()}
            } else if SMAppService.mainApp.status != .notRegistered {try SMAppService.mainApp.unregister()}
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {SMAppService.openSystemSettingsLoginItems()}
        } catch {message = error.localizedDescription}
    }
    // Rezeroes the selected controller in hardware while its LED blinks.
    func calibrate() {
        guard let device else {return}
        let client = self.client
        Task {
            let data = await client.request("{\"op\":\"calibrate\",\"device\":\(device.id)}")
            let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if response?["calibrated"] as? Int != 1 {message = "Could not calibrate \(device.displayName)."}
        }
    }
    func requestAccessibility() {
        let client = self.client
        Task {
            _ = await client.request("{\"op\":\"requestAccessibility\"}")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    func addApplication() {
        let panel = NSOpenPanel();panel.directoryURL = URL(fileURLWithPath: "/Applications");panel.canChooseDirectories = false;panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            let runningID = NSWorkspace.shared.runningApplications.first(where: {$0.bundleURL == url})?.bundleIdentifier ?? id
            addProfile(runningID)
        }
    }
    func removeSelectedProfile() {
        guard configurationReady else {return}
        config.profiles.removeValue(forKey: selected);selected = "*";editRevision += 1
        Task {await save()}
    }
    func addProfile(_ id: String) {guard configurationReady else {return};config.profiles[id] = config.profiles[id] ?? config.profiles["*"] ?? Profile(); selected = id; edit {_ in}}
    func profileName(_ key: String) -> String {
        let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
        guard let id = parts.first else {return "Profile"}
        var name: String
        if id == "*" {name = "All applications"}
        else if id == "com.autodesk.fusion360" {name = "Autodesk Fusion"}
        else if id.hasPrefix("com.prusa3d.slic3r") {name = "PrusaSlicer"}
        else if let cached = appNames[id] {name = cached}
        else if let app = NSWorkspace.shared.runningApplications.first(where: {$0.bundleIdentifier == id}), let title = app.localizedName {name = title}
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {name = url.deletingPathExtension().lastPathComponent}
        else {name = id}
        appNames[id] = name
        if parts.count == 2 {
            let device = status?.devices.first(where: {String(format: "%04x:%04x", $0.vendor, $0.product) == parts[1]})
            name += " — " + (device?.name ?? "USB controller")
        }
        return name
    }
    func exportDiagnostics() {
        let panel = NSSavePanel();panel.nameFieldStringValue = "Axial-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
            struct Export: Encodable {let status: Status?; let history: [DiagnosticSample]}
            let statusData = (try? JSONEncoder().encode(Export(status: status, history: diagnostics.samples))) ?? Data()
            do {try statusData.write(to: url, options: .atomic)} catch {message = error.localizedDescription}
        }
    }
}

struct KeyRecorder: NSViewRepresentable {
    var record: (Int, UInt64, String) -> Void
    func makeNSView(context: Context) -> CaptureView {let v = CaptureView();v.record = record;DispatchQueue.main.async {v.window?.makeFirstResponder(v)};return v}
    func updateNSView(_ view: CaptureView, context: Context) {view.record = record}
    final class CaptureView: NSView {
        var record: ((Int, UInt64, String) -> Void)?
        override var acceptsFirstResponder: Bool {true}
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key")
            record?(Int(event.keyCode), UInt64(flags.rawValue), prefix + key)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {keyDown(with: event);return true}
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: Model
    @State private var confirmCalibration = false
    private let axes = ["Left / right", "Near / far", "Up / down", "Tilt", "Roll", "Spin"]
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36);Text("Axial").font(.title.bold())}
                Label(model.status == nil ? "Service stopped" : "Service running", systemImage: model.status == nil ? "circle" : "checkmark.circle.fill").foregroundStyle(model.status == nil ? Color.secondary : Color.green)
                Divider()
                Text("APPLICATION PROFILE").font(.caption).foregroundStyle(.secondary)
                NativePopup(label: "Profile", selection: model.selected,
                    choices: model.config.profiles.keys.sorted().map {PopupChoice($0, model.profileName($0))}, height: 30) {model.selected = $0}
                    .frame(maxWidth: .infinity).sidebarSurface()
                NativePopup(label: "Add application profile", choices: [
                    PopupChoice("com.autodesk.fusion360", "Autodesk Fusion"),
                    PopupChoice("com.prusa3d.slic3r.", "PrusaSlicer"),
                    PopupChoice("choose", "Choose application…")
                ], actionMenu: true, height: 30) {id in
                    if id == "choose" {model.addApplication()} else {model.addProfile(id)}
                }.frame(maxWidth: .infinity).sidebarSurface().disabled(!model.configurationReady)
                if let d = model.device, !model.selected.contains("@") {
                    SidebarButton(title: "Customize for this device") {
                        let key = model.selected + String(format: "@%04x:%04x", d.vendor, d.product)
                        model.config.profiles[key] = model.profile;model.selected = key;model.edit {_ in}
                    }.frame(maxWidth: .infinity).sidebarSurface().disabled(!model.configurationReady)
                }
                if model.selected != "*" {
                    SidebarButton(title: "Remove override") {
                        model.removeSelectedProfile()
                    }.frame(maxWidth: .infinity).sidebarSurface().disabled(!model.configurationReady)
                }
                Divider()
                if let device = model.device {
                    Label(device.displayName, systemImage: "cable.connector").font(.headline)
                    Label("USB connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
                    if (model.status?.devices.count ?? 0) > 1 {
                        NativePopup(label: "Device", selection: String(model.device?.id ?? 0),
                            choices: (model.status?.devices ?? []).map {PopupChoice(String($0.id), $0.displayName)}, height: 30) {model.recording = nil;model.selectedDevice = Int($0)}
                            .frame(maxWidth: .infinity).sidebarSurface()
                    }
                } else {Text("Connect a supported USB controller.").foregroundStyle(.secondary)}
                Spacer()
            }.padding(18).frame(minWidth: 230, idealWidth: 240, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading) {
                Picker("Settings", selection: $model.tab) {Text("Motion").tag(0);Text("Buttons").tag(1);Text("Test").tag(2);Text("Service & diagnostics").tag(3)}.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Settings tabs")
                Group {
                    if model.tab == 0 {motion.disabled(!model.configurationReady)}
                    else if model.tab == 1 {buttons.disabled(!model.configurationReady)}
                    else if model.tab == 2 {TestTab().environmentObject(model)}
                    else {service}
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).contentSurface()
                if !model.message.isEmpty {
                    Divider()
                    Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
            }.padding(12).frame(minWidth: 780)
        }.frame(minWidth: 1080, minHeight: 740)
            .groupBoxStyle(AxialGroupBoxStyle()).buttonStyle(.bordered).controlSize(.regular)
    }
    var motion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Motion").font(.title2.bold())
            if let error = model.device?.ledError, error != 0 {Text("The controller rejected the LED change (\(String(error, radix: 16))).").font(.caption).foregroundStyle(.orange)}
            HStack(spacing: 12) {
                Toggle("Translation", isOn: Binding(get: {model.profile.translation}, set: {x in model.edit {$0.translation = x}}))
                Toggle("Rotation", isOn: Binding(get: {model.profile.rotation}, set: {x in model.edit {$0.rotation = x}}))
                Toggle("Dominant axis", isOn: Binding(get: {model.profile.dominant}, set: {x in model.edit {$0.dominant = x}}))
                Toggle("LED illumination", isOn: Binding(get: {model.profile.led}, set: {x in model.edit {$0.led = x}})).disabled(model.device?.ledSupported == false)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text("Navigation")
                    NativePopup(label: "Navigation", selection: model.profile.orbit ? "orbit" : "camera", choices: [PopupChoice("orbit", "Orbit around target"), PopupChoice("camera", "Move camera")]) {choice in model.edit {$0.orbit = choice == "orbit"}}
                        .popupSurface()
                }.frame(width: 230)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(0..<6, id: \.self) {i in
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {Text(axes[i]).font(.headline);Spacer();Text("\(model.device?.axes[safe: i] ?? 0)").monospacedDigit().foregroundStyle(.secondary)}
                        AxisMeter(value: model.device?.axes[safe: i] ?? 0, label: axes[i])
                        HStack {Text("Speed").frame(width: 60, alignment: .leading);Slider(value: Binding(get: {model.profile.gain[i]}, set: {x in model.edit {$0.gain[i] = x}}), in: 0...5);Text(model.profile.gain[i], format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 35)}
                        HStack {Text("Deadzone").frame(width: 60, alignment: .leading);Slider(value: Binding(get: {model.profile.deadzone[i]}, set: {x in model.edit {$0.deadzone[i] = x}}), in: 0...100);Toggle("Invert", isOn: Binding(get: {model.profile.invert[i]}, set: {x in model.edit {$0.invert[i] = x}}))}
                    }.font(.callout).padding(4)
                }
            }
            }
            HStack(spacing: 12) {
                Button("Reset this profile") {model.edit {$0 = Profile()}}
                Button("Calibrate…") {confirmCalibration = true}
                    .disabled(model.device?.rezero != true || model.device?.calibrating == true)
                    .help(model.device?.rezero == true ? "Rezero the controller in hardware" : "This controller does not support hardware calibration")
                Text(model.device?.calibrating == true ? "Calibrating, keep your hand off the cap…" : (model.device?.deviceCalibrated == true ? "Calibrated" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.alert("Calibrate \(model.device?.displayName ?? "controller")?", isPresented: $confirmCalibration) {
            Button("Calibrate") {model.calibrate()}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Let go of the cap and do not touch it until the LED stops blinking. The controller's current position becomes its rest position.")
        }
    }
    var buttons: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Buttons").font(.title2.bold())
                Spacer()
                if let device = model.device, let layout = device.layout {
                    Text("\(device.displayName) · \(layout.buttons.count) buttons").foregroundStyle(.secondary)
                }
            }
            if model.device?.layout == nil {
                Text(model.device == nil ? "Connect a controller to configure its buttons." : "Button layout is unavailable for this controller.").foregroundStyle(.secondary)
            }
            ScrollView {
            LazyVStack(spacing: 10) {
            ForEach(model.device?.layout?.buttons ?? []) {button in
                let i = button.id
                GroupBox { VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(((model.device?.buttons ?? 0) & (1 << i)) != 0 ? Color.green : Color.secondary.opacity(0.2)).frame(width: 10, height: 10)
                        Text(button.name).font(.headline)
                        Spacer()
                        if model.recording == i {
                            Text("Press shortcut…").foregroundStyle(.tint).background(KeyRecorder {key, flags, label in model.edit {$0.buttons[i] = ButtonAction(keyCode: key, modifiers: flags, label: label)};model.recording = nil}.frame(width: 1, height: 1))
                            Button("Cancel") {model.recording = nil}
                        } else {Button(model.profile.buttons[i].keyCode == nil ? "Record shortcut" : (model.profile.buttons[i].label ?? "Replace shortcut")) {model.recording = i}}
                        Button {model.edit {$0.buttons[i] = ButtonAction()}} label: {Image(systemName: "xmark.circle")}.buttonStyle(.borderless).accessibilityLabel("Clear assignment for \(button.name)").help("Clear assignment")
                    }
                    HStack(spacing: 12) {
                    Text("Command").frame(width: 90, alignment: .leading)
                    NativePopup(label: "Command", selection: model.profile.buttons[i].command ?? "",
                        choices: [PopupChoice("", "No app command")] + (model.commands[String(model.selected.split(separator: "@").first ?? "*")] ?? []).map {PopupChoice($0.id, $0.label)}) {x in
                            model.edit {$0.buttons[i] = ButtonAction(command: x.isEmpty ? nil : x)}
                        }.popupSurface().frame(width: 320)
                    Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                    Text("Driver action").frame(width: 90, alignment: .leading)
                    NativePopup(label: "Driver action", selection: model.profile.buttons[i].action ?? "", choices: [
                        PopupChoice("", "No driver action"), PopupChoice("dominant", "Toggle dominant axis"),
                        PopupChoice("translation", "Toggle translation"), PopupChoice("rotation", "Toggle rotation"),
                        PopupChoice("faster", "Increase speed"), PopupChoice("slower", "Decrease speed"), PopupChoice("fit", "Fit view")
                    ]) {x in model.edit {$0.buttons[i] = ButtonAction(action: x.isEmpty ? nil : x)}}.popupSurface().frame(width: 320)
                    Spacer(minLength: 0)
                    }
                }.padding(6) }
            }
            }.padding(.vertical, 2).padding(.trailing, 8)
            }.scrollContentBackground(.hidden).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    var service: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {Text("Service & diagnostics").font(.title2.bold());Spacer();Button("Export…", action: model.exportDiagnostics)}
            HStack {Spacer();Toggle("Start at login", isOn: Binding(get: {model.launchAtLogin}, set: {model.login($0)}))}
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(model.status?.accessibility == true ? "Keyboard shortcuts enabled" : "Keyboard shortcuts need permission", systemImage: "keyboard");Spacer()
                        Button(action: model.requestAccessibility) {Text("Accessibility…").frame(width: 145)}.disabled(model.status == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            DiagnosticsCharts(samples: model.diagnostics.samples).equatable()
            WebCompatibilityView(model: model, setup: model.webSetup)
            if model.status?.mock == true {Label("Mock input service", systemImage: "testtube.2").foregroundStyle(.orange)}
            Spacer(minLength: 0)
        }
    }
}
struct WebCompatibilityView: View {
    @ObservedObject var model: Model
    @ObservedObject var setup: WebSetupCoordinator
    var body: some View {
        GroupBox("WebSocket API compatibility") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable web navigation", isOn: Binding(get: {model.config.web?.enabled ?? true}, set: {value in model.editWeb {$0.enabled = value}}))
                    .disabled(setup.busy)
                HStack {
                    Text(model.config.web?.enabled == false ? "Web navigation is disabled." : (setup.ready ? (model.status?.web?.listening == true ? "Ready" : (model.status?.web?.error.isEmpty == false ? (model.status?.web?.error ?? "") : setup.message)) : setup.message))
                        .font(.caption).textSelection(.enabled)
                    Spacer()
                    if setup.busy {ProgressView().controlSize(.small)}
                    Button(setup.ready ? "Check / Repair…" : "Set Up…") {Task {await model.setUpWeb()}}
                        .disabled(setup.busy || model.config.web?.enabled == false || model.status?.mock != false)
                }
                if !setup.ready && model.config.web?.enabled != false {
                    Text("Allow Axial to configure its local address and approve its web certificate. macOS may ask for your password. Axial checks this setup automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6).disabled(!model.configurationReady)
        }
    }
}
extension Array {subscript(safe index: Int) -> Element? {indices.contains(index) ? self[index] : nil}}
