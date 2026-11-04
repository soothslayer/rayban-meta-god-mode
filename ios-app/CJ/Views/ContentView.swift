import SwiftUI
import PhotosUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveConversation
    @ObservedObject var glasses: GlassesManager
    @State private var tab = 0
    @State private var message = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showingError = false
    @State private var errorMessage = ""
    @FocusState private var typing: Bool
    private let mint = Color(red: 0.48, green: 0.93, blue: 0.75)

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { conversation }
                .tabItem { Label("Conversation", systemImage: "waveform") }.tag(0)
            NavigationStack { devices }
                .tabItem { Label("Glasses", systemImage: "eyeglasses") }.tag(1)
            NavigationStack { SetupView(model: model, live: live) }
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .onReceive(model.$error) { message in
            guard let message else { return }
            Task { @MainActor in errorMessage = message; showingError = true }
        }
        .onReceive(glasses.$error) { message in
            guard let message else { return }
            Task { @MainActor in errorMessage = message; showingError = true }
        }
        .onChange(of: live.active) { _, active in
            if active { tab = 0 }
        }
        .alert("CJ needs your attention", isPresented: $showingError) {
            Button("OK") { model.error = nil; glasses.error = nil }
        } message: { Text(errorMessage) }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.pairing == nil ? .orange : mint).frame(width: 7, height: 7)
                Text(model.connection).font(.caption)
                Spacer()
                if live.active { Label("LIVE", systemImage: "record.circle.fill").foregroundStyle(mint).font(.caption.bold()) }
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.turns.isEmpty && !live.active { welcome }
                        ForEach(model.turns) { turn in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(turn.role == "user" ? "YOU" : "CJ").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(turn.role == "user" ? .secondary : mint)
                                Text(turn.text).font(.body).textSelection(.enabled).accessibilityIdentifier("turn-\(turn.role)")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18).background(turn.role == "user" ? Color.white.opacity(0.06) : mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        }
                        if model.busy {
                            HStack { ProgressView(); Text("Thinking on your Mac…").font(.callout); Spacer(); Button("Cancel") { model.cancelRequest() } }
                        }
                        if live.active {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(live.status, systemImage: "waveform").foregroundStyle(mint).font(.callout)
                                if !live.heard.isEmpty { Text(live.heard).foregroundStyle(.secondary) }
                                if !live.said.isEmpty { Text(live.said) }
                                if !live.route.isEmpty { Text(live.route).font(.caption).foregroundStyle(.secondary) }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        }
                        if let notice = model.notice {
                            HStack(alignment: .top) {
                                Text(notice).font(.footnote).foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Button { model.notice = nil } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Dismiss notice")
                            }.padding(.horizontal, 4)
                        }
                        if let number = model.pendingNumber, let url = URL(string: "tel:\(number)") {
                            Link(destination: url) { Label("Call \(number)", systemImage: "phone.fill") }.buttonStyle(.bordered)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(22)
                }
                .onChange(of: model.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: live.said) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .navigationTitle("CJ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Stop speaking", systemImage: "speaker.slash") { model.stopSpeaking() }.disabled(live.active)
                    Button("Clear conversation", systemImage: "trash") { model.clear() }.disabled(model.busy || live.active)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(mint).padding(.top, 28)
            VStack(alignment: .leading, spacing: 12) {
                Text("A little less phone.\nA little more possibility.").font(.system(size: 32, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                Text("Your glasses, your Mac, and a conversation. Ask CJ to see what you see or get something done.")
                    .foregroundStyle(.secondary).lineSpacing(4)
            }
            if model.pairing == nil {
                Button { tab = 2 } label: { HStack { Text("Connect your Mac"); Spacer(); Image(systemName: "arrow.up.right") }.padding(6) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).accessibilityIdentifier("connect-mac")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    suggestion("What’s on my calendar today?", icon: "calendar")
                    suggestion("Take a note: a new idea", icon: "note.text")
                    suggestion("What’s on my screen?", icon: "desktopcomputer")
                }
            }
            Label("AI keys stay on your Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.padding(.bottom, 20)
    }

    private func suggestion(_ text: String, icon: String) -> some View {
        Button { message = text; typing = true } label: { Label(text, systemImage: icon).font(.callout).foregroundStyle(.white.opacity(0.8)) }
    }

    private var composer: some View {
        VStack(spacing: 12) {
            if let data = model.attachedImage, let image = UIImage(data: data) {
                HStack {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Photo ready to send").font(.caption)
                    Spacer()
                    Button("Remove") { model.attachedImage = nil }.font(.caption)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) { Image(systemName: "plus.circle").font(.title2) }
                    .accessibilityLabel("Attach a photo").disabled(model.busy || live.active || model.pairing == nil)
                TextField("Ask CJ…", text: $message, axis: .vertical)
                    .lineLimit(1...4).focused($typing).accessibilityIdentifier("message-input")
                    .disabled(live.active || model.pairing == nil)
                Button {
                    let text = message; message = ""; typing = false; model.send(text)
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .accessibilityLabel("Send message").accessibilityIdentifier("send-message")
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 4000 || model.busy || live.active || model.pairing == nil)
            }.padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            Button {
                typing = false
                if model.pairing == nil { tab = 2 }
                else { model.toggleLive() }
            } label: {
                Label(live.active ? "End conversation" : "Talk to CJ", systemImage: live.active ? "stop.circle.fill" : "waveform")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).tint(live.active ? .red : mint)
                .foregroundStyle(live.active ? .white : .black).disabled(model.busy)
                .accessibilityIdentifier("talk-button")
            if model.pairing == nil {
                Text("First, connect your Mac. Tap Talk to open Setup.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Listen for CJ", isOn: Binding(get: { model.wakeWordEnabled }, set: model.setWakeWordEnabled))
                    .font(.subheadline).tint(mint)
                    .disabled(model.busy || (live.active && !model.wakeWordEnabled))
                    .accessibilityIdentifier("conversation-wake-toggle")
                if model.wakeWordEnabled {
                    Text(model.wakeWordStatus).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("wake-word-status")
                }
            }
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10).background(.ultraThinMaterial)
            .onChange(of: photoItem) { _, item in
                Task {
                    do { if let data = try await item?.loadTransferable(type: Data.self) { try model.attach(data) } }
                    catch { model.error = error.localizedDescription }
                    photoItem = nil
                }
            }
    }

    private var devices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "eyeglasses").font(.system(size: 80, weight: .light)).foregroundStyle(mint).frame(maxWidth: .infinity).padding(.vertical, 30)
                Text("A different point of view.").font(.largeTitle.bold())
                Text("\(glasses.status) · \(glasses.deviceCount) discovered").foregroundStyle(.secondary)
                Text("Pair your glasses in the Meta AI app and enable Developer Mode, then link CJ here. Bluetooth audio also works without camera access.").foregroundStyle(.secondary)
                if glasses.registered {
                    if let frame = glasses.frame { Image(uiImage: frame).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20)) }
                    Button(glasses.cameraActive || glasses.starting ? "Stop camera" : "Preview glasses camera") {
                        if glasses.cameraActive || glasses.starting { glasses.stop() }
                        else { Task {
                            do { try await glasses.start() }
                            catch is CancellationError { }
                            catch { model.error = error.localizedDescription }
                        } }
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    Button("Attach what I’m looking at", systemImage: "camera") {
                        Task {
                            do { try model.attach(await glasses.capture()); tab = 0 }
                            catch is CancellationError { }
                            catch { model.error = error.localizedDescription }
                        }
                    }.buttonStyle(.bordered).disabled(model.busy || live.active || glasses.starting)
                } else {
                    Button("Link with Meta AI", systemImage: "link") { Task { await glasses.register() } }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                }
                Text("Camera access requires physical glasses and an iPhone. The camera stops when CJ enters the background. During live voice, a request to look sends one fresh camera frame to your Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }.navigationTitle("Glasses")
    }
}
