import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor
final class BridgeModel: ObservableObject {
    #if CJ_MUSE
    let muse = MuseRelay()
    #endif
    @Published var assistant = "codex"
    var assistantName: String {
        switch assistant {
        case "codex": "Codex"
        case "claude-code": "Claude Code"
        case "muse": "Muse"
        default: "Gemini API"
        }
    }
    @Published var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var message = "Starting CJ Bridge…"
    @Published var running = false
    @Published var checking = false
    @Published var managed = false
    @Published var accounts = "Checking this Mac’s sign-ins…"
    @Published var network = UserDefaults.standard.string(forKey: "pairingNetwork") ?? "wifi"
    @Published var tailnetHint = "Checking Tailscale on this Mac…"
    @Published var checkingNetwork = false
    @Published var pairingAddress = ""
    @Published var qr: NSImage?
    private var lanURL: String?
    private var tailnetURL: String?
    private var networkCheck: Task<Void, Never>?
    private var process: Process?
    private var monitor: Task<Void, Never>?
    private var accountCheck: Task<Void, Never>?
    private var token = ""
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cj/config.json")

    init() {
        if let config = try? readConfig() {
            if let saved = config["provider"] as? String, ["codex", "claude-code", "gemini", "muse"].contains(saved) { assistant = saved }
            workspace = config["workspace"] as? String ?? workspace
            token = config["token"] as? String ?? ""
        }
    }

    private func readConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else {
            throw NSError(domain: "CJBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "CJ’s settings file could not be read."])
        }
        return result
    }

    @discardableResult func save() -> Bool {
        do {
            var directory: ObjCBool = false
            let path = NSString(string: workspace).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                message = "Choose an existing working folder."; return false
            }
            var config = try readConfig()
            config["provider"] = assistant
            config["workspace"] = path
            if (config["token"] as? String)?.isEmpty != false { config["token"] = UUID().uuidString + UUID().uuidString }
            token = config["token"] as? String ?? ""
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            workspace = path
            message = "Saved. New conversations use \(assistantName)."
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspace)
        if panel.runModal() == .OK, let url = panel.url { workspace = url.path; save() }
    }

    func start() {
        guard process?.isRunning != true, monitor == nil else { return }
        guard save() else { return }
        monitor = Task { [weak self] in
            guard let self else { return }
            if let health = try? await self.fetch("/health"), health["name"] as? String == "CJ" {
                self.running = true
                self.message = "An existing CJ brain is running. Its terminal owns the process."
                self.refreshNetwork()
                self.refreshAccounts()
                self.monitor = nil
                return
            }
            do {
                guard let url = Bundle.main.url(forResource: "runtime", withExtension: "json"),
                      let runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
                      let python = runtime["python"], let brain = runtime["brain"] else {
                    throw NSError(domain: "CJBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rebuild CJ Bridge from this project."])
                }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: python)
                child.arguments = ["-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8765", "--timeout-graceful-shutdown", "3"]
                child.currentDirectoryURL = URL(fileURLWithPath: brain)
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "CJ_PROVIDER")
                environment.removeValue(forKey: "CJ_WORKSPACE")
                environment.removeValue(forKey: "CJ_FORCE_MOCK")
                environment["CJ_HOME"] = self.configURL.deletingLastPathComponent().path
                environment["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
                environment.removeValue(forKey: "CJ_MUSE_SOCKET")
                #if CJ_MUSE
                do {
                    try self.muse.start()
                    environment["CJ_MUSE_SOCKET"] = self.muse.socketPath
                } catch { self.muse.notice = "Could not start the local Muse connection. Restart CJ Bridge." }
                #endif
                child.environment = environment
                // CLI diagnostics can contain account or conversation data.
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                child.terminationHandler = { [weak self] _ in
                    Task { @MainActor in self?.running = false; self?.managed = false; self?.process = nil; self?.clearNetwork(); self?.message = "CJ Bridge stopped." }
                }
                self.process = child
                try child.run()
                self.managed = true
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    if let health = try? await self.fetch("/health"), health["name"] as? String == "CJ" {
                        self.running = true; self.message = "Ready. Keep this Mac awake while using CJ."
                        self.refreshNetwork()
                        self.refreshAccounts()
                        self.monitor = nil
                        return
                    }
                    if !child.isRunning { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                self.message = "The bridge couldn’t start. Check that port 8765 is free and the project’s Python environment is installed."
            } catch {
                if !Task.isCancelled { self.message = error.localizedDescription }
            }
            self.monitor = nil
        }
    }

    func stop() {
        #if CJ_MUSE
        muse.stop()
        #endif
        monitor?.cancel(); monitor = nil
        accountCheck?.cancel(); accountCheck = nil
        clearNetwork()
        if process?.isRunning == true { process?.terminate(); message = "Stopping CJ Bridge…" }
        else { process = nil; running = false; managed = false; message = "CJ Bridge stopped." }
    }

    private func fetch(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
        request.timeoutInterval = path == "/health" ? 2 : 135
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CJBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "The running brain needs the latest CJ Bridge update."])
        }
        return object
    }

    func refreshAccounts() {
        guard !checking else { return }
        checking = true
        accountCheck = Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            do {
                let status = try await self.fetch("/api/bridge/status")
                let accounts = status["accounts"] as? [String: [String: Any]] ?? [:]
                self.accounts = [("codex", "Codex / ChatGPT"), ("claude-code", "Claude Code")].map { key, title in
                    let account = accounts[key] ?? [:]
                    if let error = account["error"] as? String { return "\(title): \(error)" }
                    return "\(title): " + (account["subscription"] as? Bool == true ? "signed in with subscription" : "sign in on this Mac")
                }.joined(separator: "\n")
                if self.running, self.lanURL == nil, let address = status["url"] as? String {
                    self.lanURL = address
                    self.updateQR()
                }
            } catch { self.accounts = error.localizedDescription }
        }
    }

    private func clearNetwork() {
        networkCheck?.cancel()
        networkCheck = nil
        checkingNetwork = false
        lanURL = nil
        tailnetURL = nil
        updateQR()
    }

    func refreshNetwork() {
        clearNetwork()
        checkingNetwork = true
        tailnetHint = "Checking Tailscale on this Mac…"
        networkCheck = Task {
            defer { if !Task.isCancelled { checkingNetwork = false } }
            do {
                let status = try await fetch("/api/bridge/pairing")
                guard !Task.isCancelled else { return }
                lanURL = status["lan"] as? String
                tailnetURL = status["tailscale"] as? String
                tailnetHint = status["hint"] as? String ?? ""
                if UserDefaults.standard.string(forKey: "pairingNetwork") == nil {
                    network = tailnetURL == nil ? "wifi" : "tailscale"
                }
                updateQR()
            } catch {
                if !Task.isCancelled { tailnetHint = error.localizedDescription }
            }
        }
    }

    func chooseNetwork(_ choice: String) {
        network = choice
        UserDefaults.standard.set(choice, forKey: "pairingNetwork")
        updateQR()
    }

    private func updateQR() {
        pairingAddress = (network == "tailscale" ? tailnetURL : lanURL) ?? ""
        qr = nil
        guard let payload = pairingPayload else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
           let image = CIContext().createCGImage(output, from: output.extent) {
            qr = NSImage(cgImage: image, size: NSSize(width: 240, height: 240))
        }
    }

    private var pairingPayload: Data? {
        guard !pairingAddress.isEmpty, !token.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["v": 1, "url": pairingAddress, "token": token])
    }

    func copyPairing() {
        guard let data = pairingPayload, let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct BridgeView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "eyeglasses").font(.system(size: 38)).foregroundStyle(.mint)
                Text("CJ Bridge").font(.largeTitle.bold())
                Spacer()
                Label(model.running ? "Running" : "Stopped", systemImage: model.running ? "circle.fill" : "circle")
                    .foregroundStyle(model.running ? .green : .secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Assistant", selection: $model.assistant) {
                        Text("Codex · ChatGPT subscription").tag("codex")
                        Text("Claude Code · Claude subscription").tag("claude-code")
                        Text("Muse · gadget chat").tag("muse")
                        Text("Gemini · API").tag("gemini")
                    }.onChange(of: model.assistant) { _, _ in model.save() }
                    if model.assistant == "muse" {
                        #if CJ_MUSE
                        Text("Muse receives transcribed speech and typed messages through its gadget connection.").font(.callout)
                        if model.running && !model.managed {
                            Text("Stop the separately running brain and restart CJ Bridge to use Muse.")
                        }
                        MuseSetupButton(relay: model.muse)
                        #else
                        Text("Rebuild CJ Bridge with the muse-voice-ios source to enable Muse. See the Mac bridge guide.")
                        #endif
                    } else {
                        HStack { TextField("Working folder", text: $model.workspace).onSubmit { model.save() }; Button("Choose…") { model.chooseFolder() } }
                        Text("Full access · tool approvals off").font(.callout).foregroundStyle(.secondary)
                        Text(model.accounts).font(.callout).textSelection(.enabled)
                        HStack {
                            Button(model.checking ? "Checking…" : "Refresh sign-ins") { model.refreshAccounts() }.disabled(model.checking || !model.running)
                            Spacer()
                            Text("Sign in from Terminal: codex login  ·  claude auth login").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.padding(8)
            }
            HStack(spacing: 24) {
                if let qr = model.qr { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 210, height: 210).padding(12).background(.white).cornerRadius(12) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pair your iPhone").font(.title2.bold())
                    Picker("Connection", selection: Binding(get: { model.network }, set: model.chooseNetwork)) {
                        Text("Local Wi-Fi").tag("wifi")
                        Text("Tailscale").tag("tailscale")
                    }.pickerStyle(.segmented)
                    Text(model.network == "tailscale" ? model.tailnetHint : "On the same Wi-Fi, open CJ → Setup and scan this code.")
                        .font(.callout).textSelection(.enabled)
                    if !model.pairingAddress.isEmpty {
                        Text(model.pairingAddress).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy pairing payload") { model.copyPairing() }.disabled(model.pairingAddress.isEmpty)
                        Button("Refresh addresses") { model.refreshNetwork() }.disabled(!model.running || model.checkingNetwork)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(model.message).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.running ? "Stop bridge" : "Start bridge") { if model.running { model.stop() } else { model.start() } }
                    .buttonStyle(.borderedProminent).tint(.mint).disabled(model.running && !model.managed)
            }
        }.padding(28).frame(minWidth: 720, minHeight: 580)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BridgeModel()
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), submenu = NSMenu(), item = NSMenuItem()
        submenu.addItem(withTitle: "Quit CJ Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CJ Bridge"; window.contentView = NSHostingView(rootView: BridgeView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.start()
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CJBridgeApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
