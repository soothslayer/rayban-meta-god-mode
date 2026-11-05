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
                Text("Open CJ Bridge on your Mac, choose Codex or Claude Code, and pair over the same Wi-Fi.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Subscription mode uses this Mac’s existing ChatGPT or Claude login. Your iPhone transcribes each question and speaks the reply. Choose Gemini on the Mac if you prefer its streaming API voice.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                Picker("Speech language", selection: $model.transcriptionLanguage) {
                    Text("English").tag("en-US")
                    Text("Auto detect").tag("")
                    Text("Hindi").tag("hi-IN")
                    Text("Spanish").tag("es-ES")
                    Text("French").tag("fr-FR")
                    Text("German").tag("de-DE")
                    Text("Japanese").tag("ja-JP")
                }.disabled(live.active)
                Toggle("Read text replies aloud", isOn: $model.speakReplies)
                Toggle("Listen for CJ", isOn: Binding(get: { model.wakeWordEnabled }, set: model.setWakeWordEnabled))
                    .disabled(model.pairing == nil || model.busy || (live.active && !model.wakeWordEnabled))
                    .accessibilityIdentifier("wake-word-toggle")
                if model.wakeWordEnabled { Text(model.wakeWordStatus).font(.footnote).foregroundStyle(.tint) }
                Text("Enable once after opening CJ, then say “CJ” or “Hey CJ” and your question. After “bye” or End conversation, CJ listens for the wake word again. Turn this switch off to release the microphone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Wake recognition runs on this iPhone. Subscription mode sends transcribed questions and requested photos to your Mac; Gemini mode streams conversation audio. Listening keeps the microphone active and may continue with the screen locked, but cannot restart after you force-quit CJ or iOS ends the audio session.")
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
