import SwiftUI
import AVFoundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    @Published private(set) var connection = "Mac not paired"
    @Published private(set) var providers = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var pendingNumber: String?
    @Published var attachedImage: Data?
    @Published var speakReplies = true
    let live = LiveConversation()
    let glasses = GlassesManager()
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var speechOwner: UUID?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    let uiTesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

    init() {
        if !uiTesting {
            do { pairing = try KeychainStore.load() }
            catch { self.error = error.localizedDescription }
        }
        if pairing != nil { connection = "Paired · connection not checked" }
        live.onTurn = { [weak self] heard, said in
            if !heard.isEmpty { self?.append("user", heard) }
            if !said.isEmpty { self?.append("assistant", said) }
        }
        live.onFailure = { [weak self] in self?.error = $0 }
        live.onPhone = { [weak self] in self?.handle($0) }
        live.photo = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.glasses.capture()
        }
    }

    func setup() { if !uiTesting { glasses.configure() } }

    func pair(_ candidate: Pairing) async throws {
        guard !busy, !live.active else { throw CJError("End the current conversation before changing your Mac.") }
        busy = true
        defer { busy = false }
        let health = try await BrainClient(pairing: candidate).verify()
        if !uiTesting { try KeychainStore.save(candidate) }
        pairing = candidate
        connection = "Mac connected"
        providers = health.providers.filter(\.value).map(\.key).sorted().joined(separator: ", ")
        if providers == "mock" { notice = "Your Mac is using its offline mock provider. Add a Gemini key on the Mac for AI and live voice." }
    }

    func forget() {
        guard !busy, !live.active else { return }
        do {
            if !uiTesting { try KeychainStore.delete() }
            pairing = nil; connection = "Mac not paired"; providers = ""
            clear()
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000, !busy, !live.active, let pairing else { return }
        let history = turns
        let image = attachedImage
        attachedImage = nil
        append("user", text)
        busy = true
        let generation = UUID()
        self.generation = generation
        request = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.busy = false; self.request = nil } }
            do {
                let answer = try await BrainClient(pairing: pairing).ask(text, history: history, image: image)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.append("assistant", answer.spoken)
                if let details = answer.details, !details.isEmpty, details != answer.spoken { self.notice = details }
                if self.speakReplies { await self.speak(answer) }
                if let phone = answer.phone { self.handle(phone) }
                if let timer = answer.timer { self.handle(PhoneAction(action: "timer", seconds: timer.seconds, label: timer.label)) }
                if answer.dictation != nil { self.handle(PhoneAction(action: "dictation")) }
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func toggleLive() {
        if live.active { live.stop(); return }
        guard !busy, let pairing else { return }
        stopSpeaking()
        live.start(pairing: pairing, history: turns)
    }

    func cancelRequest() {
        generation = UUID()
        request?.cancel(); request = nil; busy = false
        notice = "Stopped waiting for the Mac. An action already received by the Mac may still finish."
    }

    func clear() {
        guard !busy, !live.active else { return }
        turns.removeAll(); attachedImage = nil; notice = nil; pendingNumber = nil
        stopSpeaking()
    }

    func attach(_ data: Data) throws {
        guard let image = UIImage(data: data) else { throw CJError("That photo couldn’t be opened.") }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.75), jpeg.count <= 5_500_000 else { throw CJError("Choose a smaller photo.") }
        attachedImage = jpeg
    }

    private func append(_ role: String, _ text: String) {
        turns.append(Turn(role: role, text: text))
        if turns.count > 100 { turns.removeFirst(turns.count - 100) }
    }

    private func speak(_ answer: Answer) async {
        stopSpeaking()
        let owner = UUID()
        speechOwner = owner
        do {
            try await AudioSessionCoordinator.shared.activate(owner, live: false)
            guard speechOwner == owner, !Task.isCancelled else {
                await AudioSessionCoordinator.shared.deactivate(owner)
                return
            }
            if let encoded = answer.voice_b64, let data = Data(base64Encoded: encoded), let audio = try? AVAudioPlayer(data: data) {
                player = audio; audio.play()
            } else {
                let utterance = AVSpeechUtterance(string: answer.spoken)
                utterance.voice = AVSpeechSynthesisVoice(language: answer.language ?? "en")
                speech.speak(utterance)
            }
        } catch {
            stopSpeaking()
            self.notice = "The reply is available as text; audio playback couldn’t start."
        }
    }

    func stopSpeaking() {
        speech.stopSpeaking(at: .immediate); player?.stop(); player = nil
        if let owner = speechOwner {
            speechOwner = nil
            Task { await AudioSessionCoordinator.shared.deactivate(owner) }
        }
    }

    private func handle(_ action: PhoneAction) {
        switch action.action {
        case "call_number":
            let number = (action.number ?? "").filter { "0123456789+".contains($0) }
            if !number.isEmpty { pendingNumber = number; notice = "Tap Call to continue in the Phone app." }
        case "timer":
            guard let seconds = action.seconds, (1...604800).contains(seconds) else { error = "The Mac returned an invalid timer."; return }
            Task {
                do {
                    let center = UNUserNotificationCenter.current()
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw CJError("Allow notifications in Settings to receive timers.") }
                    let content = UNMutableNotificationContent()
                    content.title = "CJ timer"; content.body = action.label ?? "Your timer is done."; content.sound = .default
                    try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(seconds), repeats: false)))
                    notice = "Timer scheduled for \(seconds) seconds."
                } catch { self.error = error.localizedDescription }
            }
        case "phone_task": notice = "This task needs Android’s phone agent. CJ for iOS can’t tap or complete purchases inside other apps. Complete it in the app yourself."
        case "dictation": notice = "Continuous meeting dictation isn’t available in this iOS version. You can still ask CJ to save a single note on your Mac."
        case "translate": notice = "Two-way translation with separate speaker routing isn’t available in this iOS version."
        case "visual_memory": notice = "Automatic visual memory isn’t available in this iOS version. Use a photo attachment or ask CJ to look during a live conversation."
        default: notice = "The Mac requested a phone feature this iOS version doesn’t support: \(action.action)."
        }
    }
}
