import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveConversation
    @State private var address = ""
    @State private var token = ""
    @State private var qrText = ""
    @State private var scanning = false
    @State private var connecting = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                Label("One Mac. Your own assistant.", systemImage: "desktopcomputer").font(.headline)
                Text("Start the brain on your Mac, then pair over the same Wi-Fi. Your Mac runs the AI and its tools.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Live voice needs a Gemini API key on the Mac. After connecting below, return to Conversation and tap Talk to CJ. Glasses are optional for voice.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("cd ~/git/rayban-meta-god-mode/brain\n./set-key.sh gemini\n./run.sh")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section {
                Button("Scan pairing QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                    .disabled(connecting || model.busy || live.active)
                TextField("http://192.168.1.20:8765", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Mac address").accessibilityIdentifier("mac-address")
                SecureField("Pairing token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pairing-token")
                Button {
                    do { connect(try Pairing(address: address, token: token)) }
                    catch { model.error = error.localizedDescription }
                } label: {
                    HStack { Text(connecting ? "Connecting…" : "Connect to Mac"); Spacer(); if connecting { ProgressView() } }
                }.disabled(connecting || model.busy || live.active || address.isEmpty || token.isEmpty)
                    .accessibilityIdentifier("pair-mac")
                if let result { Text(result).font(.footnote).foregroundStyle(.tint).accessibilityIdentifier("pair-result") }
                if model.pairing != nil {
                    Text(model.connection).font(.footnote)
                    if !model.providers.isEmpty { Text("Providers: \(model.providers)").font(.footnote).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Pair your Mac")
            } footer: {
                Text("The pairing token is the token value in ~/.cj/config.json on your Mac. It stays in this iPhone’s Keychain. Use plain HTTP only on a trusted local network; use HTTPS for remote access.")
            }
            Section("Paste a QR payload") {
                TextField("{\"v\":1,\"url\":… ,\"token\":…}", text: $qrText, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button("Use pairing payload") {
                    do { let pairing = try Pairing.parse(qr: qrText); qrText = ""; address = pairing.url.absoluteString; token = pairing.token; result = "Pairing details filled. Tap Connect to Mac." }
                    catch { model.error = error.localizedDescription }
                }.disabled(qrText.isEmpty || connecting || model.busy || live.active)
            }
            Section("Conversation") {
                Toggle("Read text replies aloud", isOn: $model.speakReplies)
                Text("Tap Talk to CJ to begin live voice. Active audio sessions may continue with the screen locked. This version has no always-on “CJ” wake word.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Mac tools work through the existing brain. Android phone automation, automatic visual memory, continuous dictation, location nudges, and split-output translation are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.pairing != nil {
                Section {
                    Button("Forget this Mac", role: .destructive) { model.forget(); address = ""; token = ""; result = nil }
                        .disabled(connecting || model.busy || live.active)
                }
            }
            Section { Text("CJ for iOS · 0.1\nBased on rayban-meta-god-mode · MIT license").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Setup")
        .onAppear { if address.isEmpty { address = model.pairing?.url.absoluteString ?? ""; token = model.pairing?.token ?? "" } }
        .sheet(isPresented: $scanning) {
            QRScanner { payload in
                scanning = false
                do {
                    let pairing = try Pairing.parse(qr: payload)
                    address = pairing.url.absoluteString; token = pairing.token
                    result = "Scanned \(pairing.url.host ?? "Mac"). Tap Connect to Mac."
                } catch { model.error = error.localizedDescription }
            }
        }
    }

    private func connect(_ pairing: Pairing) {
        connecting = true; result = nil
        Task {
            defer { connecting = false }
            do { try await model.pair(pairing); result = "Connected. You’re ready to talk." }
            catch { model.error = error.localizedDescription }
        }
    }
}
