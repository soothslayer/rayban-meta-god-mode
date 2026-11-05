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
    private var preparing = false
    private var ready = false
    private var configurationVersion = 0
    private var inputFormat: AVAudioFormat?
    private var playbackProbe: UUID?
    private var pendingPlayback: [(id: UUID, buffer: AVAudioPCMBuffer)] = []
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    var onFailure: ((String) -> Void)?
    var route = "iPhone"
    var isPlaying: Bool { queuedFrames > 0 }
    var bufferedPlaybackSeconds: Double { Double(queuedFrames) / 24_000 }

    func start() async throws -> AsyncStream<Data> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CJError("Allow microphone access in Settings to start a conversation.")
        }
        try Task.checkCancellation()
        let owner = UUID()
        sessionOwner = owner
        try await AudioSessionCoordinator.shared.activate(owner, live: true)
        try Task.checkCancellation()
        guard sessionOwner == owner else { throw CancellationError() }

        let engine = AVAudioEngine()
        self.engine = engine
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(12))
        continuation = pair.continuation
        preparing = true
        observeChanges(engine)
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try await prepare(engine)
            return pair.stream
        } catch {
            stop()
            throw error
        }
    }

    /// Selecting HFP requests a route change; it does not wait for that change.
    /// Also wait after enabling voice processing, which changes both I/O nodes.
    private func waitForRoute(_ engine: AVAudioEngine) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previous = ""
        var stableSince = clock.now
        while clock.now < deadline {
            try Task.checkCancellation()
            guard self.engine === engine else { throw CancellationError() }
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute
            let input = engine.inputNode.outputFormat(forBus: 0)
            let output = engine.outputNode.outputFormat(forBus: 0)
            let preferred = session.preferredInput
            let selected = preferred == nil || route.inputs.contains { $0.uid == preferred?.uid }
            let hasOutput = preferred?.portType != .bluetoothHFP || route.outputs.contains { $0.portType == .bluetoothHFP }
            let usable = selected && hasOutput && !route.inputs.isEmpty && !route.outputs.isEmpty
                && input.sampleRate > 0 && input.channelCount > 0 && output.sampleRate > 0 && output.channelCount > 0
            let snapshot = "\(route.inputs.map(\.uid))|\(route.outputs.map(\.uid))|\(input.sampleRate):\(input.channelCount)|\(output.sampleRate):\(output.channelCount)|\(configurationVersion)"
            if !usable || snapshot != previous { stableSince = clock.now }
            if usable && clock.now - stableSince >= .milliseconds(250) { return }
            previous = snapshot
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CJError("The microphone and speaker aren’t ready. Check the glasses’ Bluetooth connection, then try Talk again.")
    }

    private func connect(_ engine: AVAudioEngine) throws {
        guard let player, let sink = continuation else { throw CancellationError() }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else {
            throw CJError("This audio route doesn’t provide a usable microphone.")
        }
        self.inputFormat = inputFormat
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self, weak engine] buffer, _ in
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
            Task { @MainActor in
                // Do not send microphone audio until playback is ready too.
                guard let self, let engine, self.engine === engine, self.ready else { return }
                if case .dropped = sink.yield(data) {
                    self.onFailure?("The network can’t keep up with live audio. Try again on a stronger Wi-Fi connection.")
                }
            }
        }
        installedTap = true
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        // VoiceProcessingIO requires matching client formats on its input and
        // output. Let the mixer convert the Mac's 24 kHz audio to that format.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
    }

    private func prepare(_ engine: AVAudioEngine) async throws {
        ready = false
        preparing = true
        defer { preparing = false }
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard self.engine === engine, let player else { throw CancellationError() }
            // A hardware change can flush player buffers and invoke their old
            // completions. Keep unplayed chunks and invalidate those callbacks.
            playbackGeneration = UUID()
            player.stop()
            engine.stop()
            if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
            try await waitForRoute(engine)
            try connect(engine)
            let version = configurationVersion
            engine.prepare()
            try engine.start()

            // Confirm the output actually renders before allowing the first
            // question through. Silence only; no conversation or network request.
            let probe = UUID()
            playbackProbe = probe
            let silence = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 4_800)!
            silence.frameLength = silence.frameCapacity
            silence.floatChannelData![0].initialize(repeating: 0, count: Int(silence.frameLength))
            player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard self?.playbackProbe == probe else { return }
                    self?.playbackProbe = nil
                }
            }
            player.play()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while playbackProbe == probe && engine.isRunning && version == configurationVersion && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                guard self.engine === engine else { throw CancellationError() }
            }
            try Task.checkCancellation()
            guard self.engine === engine else { throw CancellationError() }
            if playbackProbe == nil, engine.isRunning, version == configurationVersion {
                ready = true
                route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone speaker"
                for chunk in pendingPlayback { schedule(chunk) }
                diagnostic("ready")
                return
            }
        }
        throw CJError("The speaker couldn’t start. Check the glasses’ Bluetooth connection, then try Talk again.")
    }

    private func observeChanges(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFailure?("Audio was interrupted. Tap Talk to reconnect when you’re ready.") }
        })
        for (name, object) in [(AVAudioSession.routeChangeNotification, nil), (.AVAudioEngineConfigurationChange, engine as AnyObject?)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self, let engine, self.engine === engine else { return }
                    self.configurationVersion += 1
                    guard !self.preparing else { return }
                    self.route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone speaker"
                    // Harmless startup notifications need no restart. A stopped
                    // engine or changed I/O format requires rebuilding BOTH paths.
                    if engine.isRunning,
                       engine.inputNode.outputFormat(forBus: 0) == self.inputFormat,
                       engine.outputNode.inputFormat(forBus: 0) == self.inputFormat {
                        if self.player?.isPlaying == false { self.player?.play() }
                        return
                    }
                    self.ready = false
                    self.preparing = true
                    self.diagnostic("reconfiguring")
                    self.reconfiguration = Task { [weak self, weak engine] in
                        guard let self, let engine else { return }
                        do { try await self.prepare(engine) }
                        catch {
                            guard !Task.isCancelled, self.engine === engine else { return }
                            self.onFailure?(error.localizedDescription)
                        }
                    }
                }
            })
        }
    }

    func play(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 1_048_576,
              player != nil,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else {
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
        let chunk = (id: UUID(), buffer: buffer)
        pendingPlayback.append(chunk)
        queuedFrames += count
        if ready { schedule(chunk) }
    }

    private func schedule(_ chunk: (id: UUID, buffer: AVAudioPCMBuffer)) {
        guard let player else { return }
        let generation = playbackGeneration
        let id = chunk.id
        let count = Int(chunk.buffer.frameLength)
        player.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.ready, self.engine?.isRunning == true else { return }
                self.pendingPlayback.removeAll { $0.id == id }
                self.queuedFrames = max(0, self.queuedFrames - count)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func interrupt() {
        playbackGeneration = UUID()
        queuedFrames = 0
        pendingPlayback.removeAll()
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    func stop() {
        reconfiguration?.cancel(); reconfiguration = nil
        ready = false
        preparing = false
        playbackProbe = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation?.finish()
        continuation = nil
        interrupt()
        engine?.stop()
        if installedTap { engine?.inputNode.removeTap(onBus: 0); installedTap = false }
        engine = nil
        player = nil
        inputFormat = nil
        if let owner = sessionOwner {
            sessionOwner = nil
            Task { await AudioSessionCoordinator.shared.deactivate(owner) }
        }
    }

    private func diagnostic(_ event: String) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        print("[CJ Audio] \(event): input=\(session.currentRoute.inputs.map { $0.portType.rawValue }), output=\(session.currentRoute.outputs.map { $0.portType.rawValue }), inputFormat=\(String(describing: inputFormat)), outputFormat=\(String(describing: engine?.outputNode.inputFormat(forBus: 0))), running=\(engine?.isRunning == true), volume=\(session.outputVolume)")
        #endif
    }
}
