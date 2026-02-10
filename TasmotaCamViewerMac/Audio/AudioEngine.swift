@preconcurrency import AVFoundation
import Foundation

/// Errors specific to AudioEngine operations.
enum AudioEngineError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone input format is invalid (0 Hz or 0 channels)."
        }
    }
}

/// Unified audio engine for microphone capture and speaker playback.
/// macOS version — no AVAudioSession (not available on macOS).
final class AudioEngine {

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The wire format matching the Tasmota I2S bridge protocol.
    private let bridgeFormat: AVAudioFormat

    /// Ring buffer for incoming audio data.
    private let ringBuffer = RingBuffer(capacity: 64 * 1024)

    /// Converter from input hardware format to bridge format for capture.
    private var captureConverter: AVAudioConverter?
    private var captureResidue = Data()
    private var captureMono = false

    var onCapturedBuffer: ((Data) -> Void)?

    private var isCaptureActive = false
    private var isPlaybackActive = false
    private var playbackPacketCount: UInt64 = 0
    private var captureCallbackCount: UInt64 = 0
    private var captureSendCount: UInt64 = 0

    /// Playback gain multiplier (applied to incoming audio before scheduling).
    /// Default 4.0 boosts the typically low ESP32 mic signal.
    var playbackGain: Float = 4.0

    // MARK: - Init

    init() {
        bridgeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Constants.audioSampleRate,
            channels: AVAudioChannelCount(Constants.audioChannels),
            interleaved: true
        )!
    }

    // MARK: - Microphone Permission

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Capture

    func startCapture() throws {
        guard !isCaptureActive else { return }

        if engine.isRunning { engine.stop() }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Input format: \(inputFormat)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.invalidInputFormat
        }

        // On macOS the mic is typically mono. AVAudioConverter can handle mono→stereo
        // but we need an intermediate format if the channel count differs.
        if inputFormat.channelCount == 1 {
            // Create a mono bridge format first, then we'll duplicate channels manually
            let monoBridgeFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Constants.audioSampleRate,
                channels: 1,
                interleaved: true
            )!
            captureConverter = AVAudioConverter(from: inputFormat, to: monoBridgeFormat)
            captureMono = true
            print("[AudioEngine] Mono mic detected — will convert mono→stereo manually")
        } else {
            captureConverter = AVAudioConverter(from: inputFormat, to: bridgeFormat)
            captureMono = false
        }
        captureResidue.removeAll()

        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.032)
        captureCallbackCount = 0
        captureSendCount = 0

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] buffer, _ in
            self?.processCapturedBuffer(buffer)
        }

        try engine.start()
        isCaptureActive = true
        print("[AudioEngine] Capture started, tapBufferSize=\(tapBufferSize), inputFormat=\(inputFormat)")
    }

    func stopCapture() {
        guard isCaptureActive else { return }

        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        captureConverter = nil
        captureResidue.removeAll()
        isCaptureActive = false
        print("[AudioEngine] Capture stopped")

        stopEngineIfIdle()
    }

    // MARK: - Playback

    func startPlayback() throws {
        guard !isPlaybackActive else { return }

        if engine.isRunning { engine.stop() }

        // Attach player node
        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }

        // Get the output hardware format
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Output hardware format: \(outputFormat)")

        // Connect: playerNode → mainMixer using the output format
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        try engine.start()
        playerNode.play()

        isPlaybackActive = true
        playbackPacketCount = 0
        ringBuffer.reset()

        print("[AudioEngine] Playback started")
        print("[AudioEngine]   engine.isRunning=\(engine.isRunning) player.isPlaying=\(playerNode.isPlaying)")
        print("[AudioEngine]   mixer vol=\(engine.mainMixerNode.outputVolume) player vol=\(playerNode.volume)")
    }

    /// Accumulation buffer — collects incoming packets and schedules in larger chunks
    /// to avoid underruns from tiny individual buffers.
    private var accumulator = Data()
    private let accumulatorTarget = 4096

    /// Enqueue raw PCM data (16 kHz, 16-bit, stereo interleaved) for speaker output.
    func enqueuePlayback(_ data: Data) {
        guard isPlaybackActive, !data.isEmpty else { return }

        playbackPacketCount += 1
        accumulator.append(data)

        guard accumulator.count >= accumulatorTarget else { return }

        scheduleAccumulatedData()
    }

    /// Flush any remaining accumulated data (e.g., on stop).
    private func flushAccumulator() {
        if !accumulator.isEmpty && isPlaybackActive {
            scheduleAccumulatedData()
        }
    }

    private func scheduleAccumulatedData() {
        let chunk = accumulator
        accumulator = Data()

        let outputFormat = playerNode.outputFormat(forBus: 0)
        let hwRate = outputFormat.sampleRate
        let hwChannels = Int(outputFormat.channelCount)
        guard hwRate > 0, hwChannels > 0 else { return }

        let srcChannels = Int(Constants.audioChannels)
        let srcBytesPerFrame = srcChannels * 2
        let srcFrameCount = chunk.count / srcBytesPerFrame
        guard srcFrameCount > 0 else { return }

        let ratio = hwRate / Constants.audioSampleRate
        let dstFrameCount = Int(Double(srcFrameCount) * ratio)
        guard dstFrameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(dstFrameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(dstFrameCount)

        let gain = playbackGain

        chunk.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            guard let floatData = pcmBuffer.floatChannelData else { return }

            for dstFrame in 0..<dstFrameCount {
                let srcFrame = min(Int(Double(dstFrame) / ratio), srcFrameCount - 1)
                let srcIdx = srcFrame * srcChannels

                let leftSample = min(max(Float(src[srcIdx]) / 32768.0 * gain, -1.0), 1.0)
                floatData[0][dstFrame] = leftSample

                if hwChannels > 1 {
                    let rightSample = srcChannels > 1
                        ? min(max(Float(src[srcIdx + 1]) / 32768.0 * gain, -1.0), 1.0)
                        : leftSample
                    floatData[1][dstFrame] = rightSample
                }
            }
        }

        playerNode.scheduleBuffer(pcmBuffer)

        if playbackPacketCount <= 5 {
            print("[AudioEngine] Scheduled \(srcFrameCount)@16kHz → \(dstFrameCount)@\(hwRate)Hz, playing=\(playerNode.isPlaying)")
        }
    }

    func stopPlayback() {
        guard isPlaybackActive else { return }

        playerNode.stop()
        isPlaybackActive = false
        ringBuffer.reset()
        print("[AudioEngine] Playback stopped (total packets: \(playbackPacketCount))")

        stopEngineIfIdle()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    // MARK: - Stop All

    func stopAll() {
        if engine.isRunning { engine.stop() }

        if isCaptureActive {
            engine.inputNode.removeTap(onBus: 0)
            captureConverter = nil
            captureResidue.removeAll()
            isCaptureActive = false
        }

        if isPlaybackActive {
            playerNode.stop()
            isPlaybackActive = false
        }

        ringBuffer.reset()
        print("[AudioEngine] All stopped")
    }

    // MARK: - Private

    private func stopEngineIfIdle() {
        if !isCaptureActive && !isPlaybackActive && engine.isRunning {
            engine.stop()
        }
    }

    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter else { return }

        captureCallbackCount += 1
        if captureCallbackCount == 1 {
            print("[AudioEngine] First capture callback: \(buffer.frameLength) frames, format=\(buffer.format)")
        } else if captureCallbackCount % 200 == 0 {
            print("[AudioEngine] Capture callbacks: \(captureCallbackCount), packets sent: \(captureSendCount)")
        }

        let ratio = Constants.audioSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        let outputFormat = converter.outputFormat
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            print("[AudioEngine] Failed to create converted buffer")
            return
        }

        var error: NSError?
        nonisolated(unsafe) var allConsumed = false
        nonisolated(unsafe) let capturedBuffer = buffer

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return capturedBuffer
        }

        if let error {
            print("[AudioEngine] Conversion error: \(error)")
            return
        }

        guard convertedBuffer.frameLength > 0 else { return }

        if captureMono {
            // Convert mono Int16 → stereo interleaved Int16 (duplicate each sample)
            let frameCount = Int(convertedBuffer.frameLength)
            let stereoBytes = frameCount * 4 // 2 channels × 2 bytes
            var rawData = Data(count: stereoBytes)
            rawData.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.bindMemory(to: Int16.self).baseAddress,
                      let src = convertedBuffer.int16ChannelData else { return }
                let srcPtr = src[0]
                for i in 0..<frameCount {
                    dstPtr[i * 2] = srcPtr[i]       // left
                    dstPtr[i * 2 + 1] = srcPtr[i]   // right (duplicate)
                }
            }
            captureResidue.append(rawData)
        } else {
            let bytesPerFrame = Int(Constants.audioChannels) * (Constants.audioBitsPerSample / 8)
            let totalBytes = Int(convertedBuffer.frameLength) * bytesPerFrame
            var rawData = Data(count: totalBytes)
            rawData.withUnsafeMutableBytes { dst in
                if let src = convertedBuffer.int16ChannelData {
                    memcpy(dst.baseAddress!, src[0], totalBytes)
                }
            }
            captureResidue.append(rawData)
        }

        let packetSize = Constants.audioBridgeBufferSize
        while captureResidue.count >= packetSize {
            let packet = captureResidue.prefix(packetSize)
            captureSendCount += 1
            if captureSendCount == 1 {
                print("[AudioEngine] Sending first capture packet: \(packet.count) bytes, residue was \(captureResidue.count)")
            }
            onCapturedBuffer?(Data(packet))
            captureResidue.removeFirst(packetSize)
        }
    }
}

// MARK: - Ring Buffer

final class RingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var writePos: Int = 0
    private var readPos: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    var availableBytes: Int {
        let w = writePos, r = readPos
        return w >= r ? w - r : capacity - r + w
    }

    @discardableResult
    func write(from src: UnsafePointer<UInt8>, count: Int) -> Int {
        let available = capacity - availableBytes - 1
        let toWrite = min(count, available)
        guard toWrite > 0 else { return 0 }
        let w = writePos
        let firstChunk = min(toWrite, capacity - w)
        memcpy(buffer + w, src, firstChunk)
        if firstChunk < toWrite { memcpy(buffer, src + firstChunk, toWrite - firstChunk) }
        writePos = (w + toWrite) % capacity
        return toWrite
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let avail = availableBytes
        let toRead = min(count, avail)
        guard toRead > 0 else { return 0 }
        let r = readPos
        let firstChunk = min(toRead, capacity - r)
        memcpy(dst, buffer + r, firstChunk)
        if firstChunk < toRead { memcpy(dst + firstChunk, buffer, toRead - firstChunk) }
        readPos = (r + toRead) % capacity
        return toRead
    }

    func reset() { readPos = 0; writePos = 0 }
}
