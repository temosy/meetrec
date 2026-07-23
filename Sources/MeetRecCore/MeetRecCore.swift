import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum MeetRecLanguage {
    public static var isJapanese: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let appleLanguages = environment["AppleLanguages"]?.lowercased() {
            if appleLanguages.contains("ja") { return true }
            if appleLanguages.contains("en") { return false }
        }
        if let lang = environment["LANG"]?.lowercased() {
            if lang.hasPrefix("ja") { return true }
            if lang.hasPrefix("en") { return false }
        }
        return Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }
}

public func t(_ ja: String, _ en: String) -> String {
    MeetRecLanguage.isJapanese ? ja : en
}

public enum MeetRecError: LocalizedError {
    case usage(String)
    case targetNotFound(String)
    case noDisplays
    case alreadyRunning(Int32)
    case notRunning
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .targetNotFound(let message):
            return message
        case .noDisplays:
            return t("録画できるディスプレイが見つかりません。", "No display is available for recording.")
        case .alreadyRunning(let pid):
            return t("meetrec はすでに録画中です。pid=\(pid) / 停止: meetrec stop", "meetrec is already recording. pid=\(pid) / Stop: meetrec stop")
        case .notRunning:
            return t("録画中の meetrec は見つかりません。", "No running meetrec recorder was found.")
        case .recordingFailed(let message):
            return message
        }
    }
}

public struct StartOptions: Sendable {
    public enum ResolutionMode: String, CaseIterable, Sendable {
        case retina
        case half

        var scaleMultiplier: CGFloat {
            switch self {
            case .retina:
                return 1
            case .half:
                return 0.5
            }
        }

        var description: String {
            switch self {
            case .retina:
                return "Retina"
            case .half:
                return "Half"
            }
        }
    }

    public var appName: String?
    public var windowID: CGWindowID?
    public var display = false
    public var fps: Int32 = 60
    public var resolutionMode: ResolutionMode = .retina
    public var outputDirectory = "~/Movies/Meetings"
    public var audioOnly = false
    public var includeCursor = false
    public var includeMicrophone = false
    public var microphoneDeviceID: String?

    public init(
        appName: String? = nil,
        windowID: CGWindowID? = nil,
        display: Bool = false,
        fps: Int32 = 60,
        resolutionMode: ResolutionMode = .retina,
        outputDirectory: String = "~/Movies/Meetings",
        audioOnly: Bool = false,
        includeCursor: Bool = false,
        includeMicrophone: Bool = false,
        microphoneDeviceID: String? = nil
    ) {
        self.appName = appName
        self.windowID = windowID
        self.display = display
        self.fps = fps
        self.resolutionMode = resolutionMode
        self.outputDirectory = outputDirectory
        self.audioOnly = audioOnly
        self.includeCursor = includeCursor
        self.includeMicrophone = includeMicrophone
        self.microphoneDeviceID = microphoneDeviceID
    }
}

public struct DisplayInfo: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let frameDescription: String

    public var title: String {
        "Display \(id) - \(width)x\(height)"
    }
}

public struct WindowInfo: Identifiable, Sendable {
    public let id: CGWindowID
    public let appName: String
    public let bundleIdentifier: String
    public let title: String
    public let width: Int
    public let height: Int

    public var displayTitle: String {
        let windowTitle = title.isEmpty ? "(no title)" : title
        return "\(appName) - \(windowTitle)"
    }
}

public struct ShareableTargets: Sendable {
    public let displays: [DisplayInfo]
    public let windows: [WindowInfo]

    public init(displays: [DisplayInfo], windows: [WindowInfo]) {
        self.displays = displays
        self.windows = windows
    }
}

public struct MicrophoneInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public var displayTitle: String {
        name
    }
}

public struct RecordingStatus: Sendable {
    public let durationSeconds: Double
    public let fileSizeBytes: Int64
    public let outputURL: URL

    public var durationText: String {
        formatDuration(durationSeconds)
    }

    public var fileSizeText: String {
        formatBytes(fileSizeBytes)
    }
}

@MainActor
public final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var recordingFinished = false
    nonisolated(unsafe) private var audioOnlyWriter: AudioOnlyAssetWriter?
    private var recordingStartedAt: Date?
    private let audioLevelQueue = DispatchQueue(label: "local.haruo.meetrec.audio-levels")

    public private(set) var targetDescription = ""
    public private(set) var systemAudioLevel = 0.0
    public private(set) var microphoneAudioLevel = 0.0
    public var onFailure: ((Error) -> Void)?
    public var onFinished: (() -> Void)?
    public var onAudioLevelsChanged: ((Double, Double) -> Void)?

    public override init() {}

    public var isRecording: Bool {
        stream != nil
    }

    public func start(options: StartOptions) async throws -> URL {
        guard stream == nil else {
            throw MeetRecError.recordingFailed(t("すでに録画中です。", "Recording is already in progress."))
        }

        if options.audioOnly {
            return try await startAudioOnly(options: options)
        }

        let target = try await makeTarget(options: options)
        let directory = try createOutputDirectory(options.outputDirectory)
        let outputURL = directory.appendingPathComponent(outputFilename(label: target.label, fileExtension: "mp4"))
        self.outputURL = outputURL
        targetDescription = target.description
        resetAudioLevels()

        let configuration = SCStreamConfiguration()
        configuration.width = target.pixelWidth
        configuration.height = target.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: options.fps)
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = options.includeCursor
        configuration.captureMicrophone = options.includeMicrophone
        if options.includeMicrophone {
            configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        }
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.streamName = "meetrec"

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.videoCodecType = .h264
        recordingConfiguration.outputFileType = .mp4

        let stream = SCStream(filter: target.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioLevelQueue)
        if options.includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioLevelQueue)
        }

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        recordingFinished = false

        try await stream.startCapture()
        recordingStartedAt = Date()
        return outputURL
    }

    public func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        if let audioOnlyWriter {
            try await audioOnlyWriter.finish()
            self.audioOnlyWriter = nil
            recordingFinished = true
        } else {
            await waitForRecordingToFinish()
        }
        self.stream = nil
        recordingOutput = nil
        recordingStartedAt = nil
        resetAudioLevels()
    }

    private func waitForRecordingToFinish() async {
        if recordingFinished {
            return
        }
        await withCheckedContinuation { continuation in
            if recordingFinished {
                continuation.resume()
            } else {
                finishContinuation = continuation
            }
        }
    }

    public func status() -> RecordingStatus? {
        guard let outputURL else { return nil }
        let seconds = recordingOutput.map { CMTimeGetSeconds($0.recordedDuration) }
            ?? recordingStartedAt.map { Date().timeIntervalSince($0) }
            ?? 0
        let outputSize = recordingOutput.map { Int64($0.recordedFileSize) } ?? 0
        let size = outputSize > 0 ? outputSize : fileSize(outputURL)
        return RecordingStatus(durationSeconds: seconds, fileSizeBytes: size, outputURL: outputURL)
    }

    public nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    public nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.recordingFinished = true
            self?.finishContinuation?.resume()
            self?.finishContinuation = nil
            self?.onFailure?(MeetRecError.recordingFailed(message))
        }
    }

    public nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.recordingFinished = true
            self?.finishContinuation?.resume()
            self?.finishContinuation = nil
            self?.onFinished?()
        }
    }

    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onFailure?(MeetRecError.recordingFailed(message))
        }
    }

    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let level = normalizedAudioLevel(from: sampleBuffer) else { return }

        switch type {
        case .audio:
            audioOnlyWriter?.append(sampleBuffer: sampleBuffer, type: .system)
        case .microphone:
            audioOnlyWriter?.append(sampleBuffer: sampleBuffer, type: .microphone)
        default:
            break
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .screen:
                return
            case .audio:
                systemAudioLevel = smoothedAudioLevel(current: systemAudioLevel, incoming: level)
            case .microphone:
                microphoneAudioLevel = smoothedAudioLevel(current: microphoneAudioLevel, incoming: level)
            @unknown default:
                return
            }
            onAudioLevelsChanged?(systemAudioLevel, microphoneAudioLevel)
        }
    }

    private func resetAudioLevels() {
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        onAudioLevelsChanged?(0, 0)
    }

    private func startAudioOnly(options: StartOptions) async throws -> URL {
        let content = try await shareableContent()
        guard let display = content.displays.sorted(by: { $0.displayID < $1.displayID }).first else {
            throw MeetRecError.noDisplays
        }

        let directory = try createOutputDirectory(options.outputDirectory)
        let outputURL = directory.appendingPathComponent(outputFilename(label: "Audio", fileExtension: "m4a"))
        self.outputURL = outputURL
        targetDescription = options.includeMicrophone
            ? t("録音のみ: Mac音声 + マイク", "audio-only: Mac audio + microphone")
            : t("録音のみ: Mac音声", "audio-only: Mac audio")
        resetAudioLevels()

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = false
        configuration.captureMicrophone = options.includeMicrophone
        if options.includeMicrophone {
            configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        }
        configuration.streamName = "meetrec-audio"

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioLevelQueue)
        if options.includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioLevelQueue)
        }

        audioOnlyWriter = try AudioOnlyAssetWriter(outputURL: outputURL, includesMicrophone: options.includeMicrophone)
        self.stream = stream
        recordingOutput = nil
        recordingFinished = false

        try await stream.startCapture()
        recordingStartedAt = Date()
        return outputURL
    }
}

enum AudioOnlyTrack: Hashable {
    case system
    case microphone
}

final class AudioOnlyAssetWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let expectedTracks: Set<AudioOnlyTrack>
    private var inputs: [AudioOnlyTrack: AVAssetWriterInput] = [:]
    private var pendingSamples: [AudioOnlyTrack: [CMSampleBuffer]] = [:]
    private var didStart = false
    private var didFinish = false
    private let lock = NSLock()

    init(outputURL: URL, includesMicrophone: Bool) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        expectedTracks = includesMicrophone ? [.system, .microphone] : [.system]
    }

    func append(sampleBuffer: CMSampleBuffer, type: AudioOnlyTrack) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, writer.status != .failed else { return }

        if inputs[type] == nil {
            guard let input = makeAudioInput(from: sampleBuffer) else { return }
            guard writer.canAdd(input) else { return }
            writer.add(input)
            inputs[type] = input
        }

        if !didStart {
            pendingSamples[type, default: []].append(sampleBuffer)
            guard expectedTracks.isSubset(of: Set(inputs.keys)) else { return }
            startWriting()
            appendPendingSamples()
            return
        }

        appendNow(sampleBuffer, to: type)
    }

    func finish() async throws {
        let (writerToFinish, inputsToFinish) = prepareToFinish()

        inputsToFinish.forEach { $0.markAsFinished() }

        guard writerToFinish.status == .writing else {
            if writerToFinish.status == .failed, let error = writerToFinish.error {
                throw error
            }
            return
        }

        await withCheckedContinuation { continuation in
            writerToFinish.finishWriting {
                continuation.resume()
            }
        }

        if writerToFinish.status == .failed, let error = writerToFinish.error {
            throw error
        }
    }

    private func prepareToFinish() -> (AVAssetWriter, [AVAssetWriterInput]) {
        lock.lock()
        defer { lock.unlock() }
        didFinish = true
        if !didStart, !pendingSamples.isEmpty {
            startWriting()
            appendPendingSamples()
        }
        return (writer, Array(inputs.values))
    }

    private func startWriting() {
        guard !didStart else { return }
        let startTime = pendingSamples.values
            .flatMap { $0 }
            .map { CMSampleBufferGetPresentationTimeStamp($0) }
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: startTime)
        didStart = true
    }

    private func appendPendingSamples() {
        let samples = pendingSamples
        pendingSamples.removeAll()
        for (type, buffers) in samples {
            for buffer in buffers {
                appendNow(buffer, to: type)
            }
        }
    }

    private func appendNow(_ sampleBuffer: CMSampleBuffer, to type: AudioOnlyTrack) {
        guard let input = inputs[type], writer.status == .writing, input.isReadyForMoreMediaData else {
            return
        }
        input.append(sampleBuffer)
    }
}

func makeAudioInput(from sampleBuffer: CMSampleBuffer) -> AVAssetWriterInput? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    else {
        return nil
    }

    let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
    let sampleRate = streamDescription.mSampleRate.isFinite && streamDescription.mSampleRate > 0
        ? streamDescription.mSampleRate
        : 48_000
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channelCount,
        AVEncoderBitRateKey: channelCount > 1 ? 192_000 : 96_000
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: formatDescription)
    input.expectsMediaDataInRealTime = true
    return input
}

func smoothedAudioLevel(current: Double, incoming: Double) -> Double {
    max(incoming, current * 0.72)
}

func normalizedAudioLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    else {
        return nil
    }

    var listSize = 0
    var blockBuffer: CMBlockBuffer?
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &listSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, listSize > 0 else { return nil }

    let rawList = UnsafeMutableRawPointer.allocate(
        byteCount: listSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawList.deallocate() }

    let audioBufferList = rawList.assumingMemoryBound(to: AudioBufferList.self)
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: listSize,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }

    let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
    var sumSquares = 0.0
    var sampleCount = 0

    for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        guard let data = buffer.mData else { continue }
        let byteCount = Int(buffer.mDataByteSize)

        if isFloat, streamDescription.mBitsPerChannel == 32 {
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = byteCount / MemoryLayout<Float>.size
            for index in 0..<count {
                let value = Double(samples[index])
                sumSquares += value * value
            }
            sampleCount += count
        } else if streamDescription.mBitsPerChannel == 16 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            let count = byteCount / MemoryLayout<Int16>.size
            for index in 0..<count {
                let value = Double(samples[index]) / Double(Int16.max)
                sumSquares += value * value
            }
            sampleCount += count
        } else if streamDescription.mBitsPerChannel == 32 {
            let samples = data.assumingMemoryBound(to: Int32.self)
            let count = byteCount / MemoryLayout<Int32>.size
            for index in 0..<count {
                let value = Double(samples[index]) / Double(Int32.max)
                sumSquares += value * value
            }
            sampleCount += count
        }
    }

    guard sampleCount > 0 else { return nil }
    let rms = sqrt(sumSquares / Double(sampleCount))
    return min(max(rms * 3.5, 0), 1)
}

struct CaptureTarget {
    let filter: SCContentFilter
    let label: String
    let description: String
    let pixelWidth: Int
    let pixelHeight: Int
}

public func loadShareableTargets() async throws -> ShareableTargets {
    let content = try await shareableContent()

    let displays = content.displays
        .sorted(by: { $0.displayID < $1.displayID })
        .map {
            DisplayInfo(
                id: $0.displayID,
                width: $0.width,
                height: $0.height,
                frameDescription: format($0.frame)
            )
        }

    let windows = content.windows
        .filter { $0.isOnScreen && $0.windowLayer == 0 }
        .sorted { lhs, rhs in
            let leftApp = lhs.owningApplication?.applicationName ?? ""
            let rightApp = rhs.owningApplication?.applicationName ?? ""
            if leftApp == rightApp { return (lhs.title ?? "") < (rhs.title ?? "") }
            return leftApp < rightApp
        }
        .map { window in
            WindowInfo(
                id: window.windowID,
                appName: window.owningApplication?.applicationName ?? "(unknown app)",
                bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "-",
                title: window.title ?? "",
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }

    return ShareableTargets(displays: displays, windows: windows)
}

func makeTarget(options: StartOptions) async throws -> CaptureTarget {
    let content = try await shareableContent()

    if options.display {
        guard let display = content.displays.sorted(by: { $0.displayID < $1.displayID }).first else {
            throw MeetRecError.noDisplays
        }
        let filter = SCContentFilter(display: display, excludingWindows: dockWindows(in: content))
        let info = SCShareableContent.info(for: filter)
        let scale = max(CGFloat(info.pointPixelScale) * options.resolutionMode.scaleMultiplier, 1)
        let width = even(Int(info.contentRect.width * scale))
        let height = even(Int(info.contentRect.height * scale))
        return CaptureTarget(
            filter: filter,
            label: "Display",
            description: "display-id=\(display.displayID) excluding=Dock mode=\(options.resolutionMode.description) resolution=\(width)x\(height)",
            pixelWidth: max(width, 2),
            pixelHeight: max(height, 2)
        )
    }

    let window: SCWindow
    if let windowID = options.windowID {
        guard let matched = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MeetRecError.targetNotFound(t("window-id=\(windowID) のウィンドウが見つかりません。meetrec list で確認してください。", "No window was found for window-id=\(windowID). Check available targets with meetrec list."))
        }
        window = matched
    } else if let appName = options.appName {
        let matches = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 }
            .filter { window in
                guard let app = window.owningApplication else { return false }
                return app.applicationName.localizedCaseInsensitiveContains(appName)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(appName)
            }
            .sorted { lhs, rhs in
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                return lhsArea > rhsArea
            }

        guard let matched = matches.first else {
            throw MeetRecError.targetNotFound(t("--app \"\(appName)\" に一致する表示中ウィンドウが見つかりません。meetrec list で対象を確認してください。", "No visible window matched --app \"\(appName)\". Check available targets with meetrec list."))
        }
        window = matched
    } else {
        throw MeetRecError.usage(t("録画対象を指定してください。", "Choose a recording target."))
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let info = SCShareableContent.info(for: filter)
    let scale = max(CGFloat(info.pointPixelScale) * options.resolutionMode.scaleMultiplier, 1)
    let width = even(Int(info.contentRect.width * scale))
    let height = even(Int(info.contentRect.height * scale))
    let app = window.owningApplication?.applicationName ?? "Window"
    let title = window.title ?? ""

    return CaptureTarget(
        filter: filter,
        label: app,
        description: "window-id=\(window.windowID) app=\"\(app)\" title=\"\(title)\" mode=\(options.resolutionMode.description) resolution=\(width)x\(height)",
        pixelWidth: max(width, 2),
        pixelHeight: max(height, 2)
    )
}

public func shareableContent() async throws -> SCShareableContent {
    try await SCShareableContent.current
}

public func availableMicrophones() -> [MicrophoneInfo] {
    let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices

    return devices
        .sorted { lhs, rhs in
            microphoneSortKey(lhs) < microphoneSortKey(rhs)
        }
        .map { device in
            MicrophoneInfo(id: device.uniqueID, name: device.localizedName)
        }
}

func microphoneSortKey(_ device: AVCaptureDevice) -> String {
    if device.uniqueID == "BuiltInMicrophoneDevice" {
        return "0-\(device.localizedName)"
    }
    if device.localizedName.localizedCaseInsensitiveContains("MacBook") {
        return "1-\(device.localizedName)"
    }
    return "2-\(device.localizedName)"
}

func dockWindows(in content: SCShareableContent) -> [SCWindow] {
    content.windows.filter { window in
        guard let app = window.owningApplication else { return false }
        return app.bundleIdentifier == "com.apple.dock"
            || app.applicationName == "Dock"
    }
}

public func createOutputDirectory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: expandTilde(path), isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

public func outputFilename(label: String, fileExtension: String = "mp4") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return "\(formatter.string(from: Date()))_\(sanitize(label)).\(fileExtension)"
}

func sanitize(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return result.isEmpty ? "Recording" : result
}

public func expandTilde(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst())
    }
    return path
}

func even(_ value: Int) -> Int {
    max(value - (value % 2), 2)
}

public func format(_ rect: CGRect) -> String {
    "x=\(Int(rect.origin.x)),y=\(Int(rect.origin.y)),w=\(Int(rect.width)),h=\(Int(rect.height))"
}

public func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "00:00:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}

public func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(max(bytes, 0))
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return index == 0 ? "\(Int(value)) \(units[index])" : String(format: "%.1f %@", value, units[index])
}

public func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
}

public func pidFileURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("meetrec", isDirectory: true)
        .appendingPathComponent("meetrec.pid")
}

public func ensureNotAlreadyRunning() throws {
    let pidURL = pidFileURL()
    guard let data = try? Data(contentsOf: pidURL),
          let raw = String(data: data, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        return
    }

    if kill(pid, 0) == 0 {
        throw MeetRecError.alreadyRunning(pid)
    }

    try? FileManager.default.removeItem(at: pidURL)
}

public func writePidFile() throws {
    let pidURL = pidFileURL()
    try FileManager.default.createDirectory(at: pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "\(getpid())\n".write(to: pidURL, atomically: true, encoding: .utf8)
}

public func cleanupPidFile() {
    try? FileManager.default.removeItem(at: pidFileURL())
}

public func stopRunningRecorder() throws {
    let pidURL = pidFileURL()
    guard let data = try? Data(contentsOf: pidURL),
          let raw = String(data: data, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        throw MeetRecError.notRunning
    }

    guard kill(pid, SIGINT) == 0 else {
        cleanupPidFile()
        throw MeetRecError.notRunning
    }
}

public final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    public init() {}

    public func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    public func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
