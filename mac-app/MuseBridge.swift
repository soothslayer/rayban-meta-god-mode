#if CJ_MUSE
import AppKit
import Network
import Security
import SwiftUI

/// A separate Keychain item belongs to CJ's gadget identity, including its rotating tokens.
private enum MuseAccountStore {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.soothslayer.cj.bridge.muse",
        kSecAttrAccount as String: "paired-gadget"
    ]

    static func load() throws -> PairedAccount? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MuseError.message("Unlock the Mac Keychain and try Muse again.")
        }
        let account = try JSONDecoder().decode(PairedAccount.self, from: data)
        try account.validate()
        return account
    }

    static func save(_ account: PairedAccount) throws {
        try account.validate()
        let value = try JSONEncoder().encode(account)
        let update = [kSecValueData as String: value]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = value
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        try require(status == errSecSuccess, "CJ could not save the Muse pairing in your Mac Keychain.")
    }
}

@MainActor
final class MuseRelay: ObservableObject {
    @Published private(set) var busy = false
    @Published var notice = ""
    private var listener: NWListener?
    private var directory: URL?
    private var pending: [UUID: Task<Void, Never>] = [:]
    var socketPath: String? { directory?.appendingPathComponent("chat").path }

    func start() throws {
        if listener != nil { return }
        let dir = URL(fileURLWithPath: "/tmp/cj-muse-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = dir
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: dir.appendingPathComponent("chat").path)
            let server = try NWListener(using: parameters)
            listener = server
            server.newConnectionHandler = { [weak self] socket in
                Task { @MainActor in self?.accept(socket) }
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, self.listener === server else { return }
                    if case .failed = state {
                        self.stop()
                        self.notice = "The Muse connection could not start. Restart CJ Bridge."
                    }
                }
            }
            server.start(queue: .main)
        } catch { stop(); throw error }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for task in pending.values { task.cancel() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func storePairing(_ account: PairedAccount) throws {
        try require(!busy, "Finish the current Muse turn before pairing again.")
        try MuseAccountStore.save(account)
        notice = "Muse is paired on this Mac."
    }

    func pairingStatus() -> String {
        do { return try MuseAccountStore.load() == nil ? "Muse needs pairing on this Mac." : "Muse is paired on this Mac." }
        catch { return error.localizedDescription }
    }

    private struct TurnRequest: Decodable { let text: String; let conversation: UUID }

    private func accept(_ socket: NWConnection) {
        guard listener != nil, pending.count < 8 else { socket.cancel(); return }
        let channel = HelperChannel(socket)
        let id = UUID()
        socket.start(queue: .main)
        let task = Task { [self] in
            defer { channel.cancel(); pending[id] = nil }
            let receiveDeadline = Task {
                do { try await Task.sleep(for: .seconds(5)); channel.cancel() } catch {}
            }
            defer { receiveDeadline.cancel() }
            do {
                let data = try await channel.receive()
                receiveDeadline.cancel()
                let request = try JSONDecoder().decode(TurnRequest.self, from: data)
                try require(!request.text.isEmpty, "Enter a question for Muse.")
                // After its one request the Python client keeps the socket open until the reply,
                // or closes it when the phone cancels. Never repost an acknowledged turn.
                socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    Task { @MainActor in self?.pending[id]?.cancel() }
                }
                let reply = try await answer(request)
                try Task.checkCancellation()
                try await channel.send(json(["reply": reply]))
            } catch {
                if !Task.isCancelled {
                    let message = (error as? MuseError)?.localizedDescription ?? "Muse could not complete the request. Check its pairing and connection on the Mac."
                    try? await channel.send(json(["error": message]))
                }
            }
        }
        pending[id] = task
    }

    private func answer(_ request: TurnRequest) async throws -> String {
        try Task.checkCancellation()
        try require(!busy, "Muse is answering another question. Try again when it finishes.")
        guard var account = try MuseAccountStore.load() else {
            throw MuseError.message("In CJ Bridge on the Mac, choose Muse and click Pair Muse.")
        }
        busy = true
        defer { busy = false }
        let api = MuseAPI()
        // Finish saving rotated credentials even if the phone cancels during refresh.
        let previous = account
        let rotation = Task { try await api.refresh(previous.credentials, identity: previous.identity, sdkToken: previous.sdkToken) }
        account.credentials = try await rotation.value
        try MuseAccountStore.save(account)
        try Task.checkCancellation()
        let vm = try await api.fetch(account.credentials)
        try Task.checkCancellation()
        let connection = MuseConnection()
        defer { connection.disconnect() }
        try await connection.connect(credentials: account.credentials, vm: vm, identity: account.identity)
        try Task.checkCancellation()
        let key = "MuseChat.\(account.identity.nodeID).\(request.conversation.uuidString)"
        let defaults = UserDefaults.standard
        let session: ChatSession
        if let data = defaults.data(forKey: key) {
            session = try JSONDecoder().decode(ChatSession.self, from: data)
        } else {
            session = ChatSession()
        }
        connection.onSessionAcknowledged = { session in
            defaults.set(try JSONEncoder().encode(session), forKey: key)
        }
        return try await connection.reply(to: request.text, session: session)
    }
}

struct MuseSetupButton: View {
    @ObservedObject var relay: MuseRelay
    @State private var showing = false

    var body: some View {
        HStack {
            Button("Pair Muse…") { showing = true }.disabled(relay.busy)
            Text(relay.notice).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { if relay.notice.isEmpty { relay.notice = relay.pairingStatus() } }
        .sheet(isPresented: $showing) { MusePairingSheet(relay: relay) }
    }
}

struct MusePairingSheet: View {
    @ObservedObject var relay: MuseRelay
    @StateObject private var bluetooth = BluetoothPairing(identity: GadgetIdentity.generate())
    @State private var token = ""
    @State private var detail = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair CJ Bridge with Muse").font(.title2.bold())
            Text(detail)
            Link("Get a gadget SDK token", destination: URL(string: "https://gadgets.muse.ai")!)
            SecureField("Gadget SDK token", text: $token).disabled(bluetooth.active)
            if bluetooth.active {
                Text(bluetooth.identity.bleName).font(.headline).textSelection(.enabled)
                Text("In Muse on your iPhone, open Settings → Devices, enable Developer mode and choose Add device. Select the name above and choose Use existing connection if asked.")
            }
            Text(bluetooth.status).foregroundStyle(.secondary)
            HStack {
                Button("Start pairing") {
                    let sdk = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard PairedAccount.validSDKToken(sdk) else { detail = "Paste a valid Muse gadget SDK token."; return }
                    if relay.busy { detail = "Finish the current Muse turn first."; return }
                    let identity = bluetooth.identity
                    bluetooth.onCredentials = { credentials in
                        try relay.storePairing(PairedAccount(identity: identity, sdkToken: sdk, credentials: credentials, chat: ChatSession()))
                    }
                    bluetooth.onPaired = { detail = "Paired. You can now talk to Muse in CJ."; bluetooth.onCredentials = nil }
                    bluetooth.start(token: sdk)
                    token = ""
                }.disabled(bluetooth.active || relay.busy || token.isEmpty)
                Spacer()
                Button(bluetooth.active ? "Cancel setup" : "Done") { dismiss() }
            }
        }.padding(24).frame(width: 440)
        .onChange(of: bluetooth.active) { _, active in if !active { bluetooth.onCredentials = nil } }
        .onAppear { detail = relay.pairingStatus() }
        .onDisappear { stopPairing() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in stopPairing() }
    }

    private func stopPairing() {
        bluetooth.stop()
        bluetooth.onCredentials = nil
        bluetooth.onPaired = nil
        token = ""
    }
}
#endif
