import AVFoundation

// AVAudioSession activation can block during Bluetooth negotiation. Serialize it
// away from the UI actor, and do not let an old session deactivate its successor.
actor AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private var owner: UUID?

    func activate(_ owner: UUID, live: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        self.owner = owner
        if live {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            if let bluetooth = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(bluetooth)
            }
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }
    }

    func deactivate(_ owner: UUID) {
        guard self.owner == owner else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.owner = nil
    }
}

@MainActor
final class LiveAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncStream<Data>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var queuedFrames = 0
    private var playbackGeneration = UUID()
    private var sessionOwner: UUID?
    private var installedTap = false
    private var reconfiguration: Task<Void, Never>?
    var onFailure: ((String) -> Void)?
    var route = "iPhone"
    var isPlaying: Bool { queuedFrames > 0 }

    func start() async throws -> AsyncStream<Data> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CJError("Allow microphone access in Settings to start a conversation.")
        }
        try Task.checkCancellation()
        let owner = UUID()
        sessionOwner = owner
        try await AudioSessionCoordinator.shared.activate(owner, live: true)
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: wireFormat),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false) else {
            throw CJError("This audio route doesn’t provide a usable microphone.")
        }
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(12))
        continuation = pair.continuation
        let sink = pair.continuation
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate)) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
            let data = Data(bytes: samples, count: Int(converted.frameLength) * 2)
            if case .dropped = sink.yield(data) {
                Task { @MainActor in self?.onFailure?("The network can’t keep up with live audio. Try again on a stronger Wi-Fi connection.") }
            }
        }
        installedTap = true
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        try engine.start()
        player.play()
        route = session.currentRoute.inputs.first?.portName ?? "iPhone microphone"
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFailure?("Audio was interrupted. Tap Talk to reconnect when you’re ready.") }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconfiguration?.cancel()
                self.reconfiguration = Task { [weak self, weak engine] in
                    // Voice processing and Bluetooth startup both emit configuration
                    // notifications. A notification alone does not mean audio failed.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let self, let engine, self.engine === engine else { return }
                    self.route = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone"
                    guard !engine.isRunning else { return }
                    let currentFormat = engine.inputNode.outputFormat(forBus: 0)
                    guard currentFormat.sampleRate == inputFormat.sampleRate,
                          currentFormat.channelCount == inputFormat.channelCount else {
                        self.onFailure?("The microphone changed format. Tap Talk to reconnect with the new audio route.")
                        return
                    }
                    do {
                        try engine.start()
                        self.player?.play()
                    } catch {
                        self.onFailure?("The audio device disconnected. Check Bluetooth, then tap Talk again.")
                    }
                }
            }
        })
        return pair.stream
    }

    func play(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 1_048_576,
              let player, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else {
            throw CJError("The Mac sent an invalid audio frame.")
        }
        let count = pcm.count / 2
        guard queuedFrames + count < 24_000 * 30 else { throw CJError("Voice playback fell behind. Start a new conversation.") }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { bytes in
            for i in 0..<count {
                let value = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                buffer.floatChannelData![0][i] = Float(value) / 32768
            }
        }
        queuedFrames += count
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - count)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func interrupt() {
        playbackGeneration = UUID()
        queuedFrames = 0
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    func stop() {
        reconfiguration?.cancel(); reconfiguration = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation?.finish()
        continuation = nil
        interrupt()
        engine?.stop()
        if installedTap { engine?.inputNode.removeTap(onBus: 0); installedTap = false }
        engine = nil
        player = nil
        if let owner = sessionOwner {
            sessionOwner = nil
            Task { await AudioSessionCoordinator.shared.deactivate(owner) }
        }
    }
}
