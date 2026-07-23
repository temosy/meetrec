import AppKit
import CoreGraphics
import MeetRecCore
import SwiftUI

enum TargetChoice: Hashable {
    case display
    case window(CGWindowID)
}

enum RecordingMode: String, CaseIterable, Identifiable {
    case video
    case audioOnly

    var id: String { rawValue }

    func title(language: InterfaceLanguage) -> String {
        switch self {
        case .video:
            return language.text("録画", "Video")
        case .audioOnly:
            return language.text("録音のみ", "Audio only")
        }
    }
}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english

    var id: String { rawValue }

    static var preferred: InterfaceLanguage {
        MeetRecLanguage.isJapanese ? .japanese : .english
    }

    var title: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }

    func text(_ ja: String, _ en: String) -> String {
        switch self {
        case .japanese:
            return ja
        case .english:
            return en
        }
    }
}

enum StatusState: Equatable {
    case ready
    case targetsUpdated
    case recording
    case recordingProgress(duration: String, fileSize: String)
    case finished
    case finishedSize(String)
    case error
    case startFailed
    case stopFailed

    func text(language: InterfaceLanguage) -> String {
        switch self {
        case .ready:
            return language.text("待機中", "Ready")
        case .targetsUpdated:
            return language.text("待機中", "Ready")
        case .recording:
            return language.text("録画中", "Recording")
        case .recordingProgress(let duration, let fileSize):
            return language.text("録画中 \(duration) / \(fileSize)", "Recording \(duration) / \(fileSize)")
        case .finished:
            return language.text("録画終了", "Recording finished")
        case .finishedSize(let fileSize):
            return language.text("録画終了 \(fileSize)", "Finished \(fileSize)")
        case .error:
            return language.text("エラー", "Error")
        case .startFailed:
            return language.text("開始できませんでした", "Could not start")
        case .stopFailed:
            return language.text("停止できませんでした", "Could not stop")
        }
    }
}

enum DetailState: Equatable {
    case chooseTarget
    case targetsUpdated
    case permissionNeeded
    case path(String)

    func text(language: InterfaceLanguage) -> String {
        switch self {
        case .chooseTarget:
            return language.text("録画対象を選んで開始してください。", "Choose a target and start recording.")
        case .targetsUpdated:
            return language.text("対象一覧を更新しました。", "Targets updated.")
        case .permissionNeeded:
            return language.text("画面収録の許可が必要な可能性があります。", "Screen recording permission may be required.")
        case .path(let path):
            return path
        }
    }
}

@MainActor
final class MeetRecViewModel: ObservableObject {
    @Published var language = InterfaceLanguage.preferred
    @Published var recordingMode = RecordingMode.video
    @Published var targets = ShareableTargets(displays: [], windows: [])
    @Published var selection: TargetChoice = .display
    @Published var fps = 60.0
    @Published var resolutionMode: StartOptions.ResolutionMode = .retina
    @Published var includeCursor = false
    @Published var includeMicrophone = false
    @Published var microphones: [MicrophoneInfo] = []
    @Published var selectedMicrophoneID = ""
    @Published var outputDirectory = "~/Movies/Meetings"
    @Published var isRecording = false
    @Published var systemAudioLevel = 0.0
    @Published var microphoneAudioLevel = 0.0
    @Published var statusState = StatusState.ready
    @Published var detailState = DetailState.chooseTarget
    @Published var errorText: String?

    private var session: RecordingSession?
    private var timer: Timer?

    var statusText: String {
        statusState.text(language: language)
    }

    var detailText: String {
        detailState.text(language: language)
    }

    func ui(_ ja: String, _ en: String) -> String {
        language.text(ja, en)
    }

    init() {
        refreshMicrophones()
        Task {
            await refreshTargets()
        }
    }

    func refreshMicrophones() {
        let loaded = availableMicrophones()
        microphones = loaded
        if selectedMicrophoneID.isEmpty || !loaded.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = loaded.first?.id ?? ""
        }
    }

    func refreshTargets() async {
        do {
            let loaded = try await loadShareableTargets()
            targets = loaded
            if loaded.displays.isEmpty, let first = loaded.windows.first {
                selection = .window(first.id)
            } else {
                selection = .display
            }
            setStatus(.targetsUpdated)
            setDetail(.targetsUpdated)
            setError(nil)
        } catch {
            setError(error.localizedDescription)
            setDetail(.permissionNeeded)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(outputDirectory), isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        do {
            let options = makeStartOptions()
            let session = RecordingSession()
            session.onFailure = { [weak self] error in
                Task { @MainActor in
                    self?.setError(error.localizedDescription)
                    self?.setStatus(.error)
                    self?.isRecording = false
                    self?.timer?.invalidate()
                    self?.resetAudioLevels()
                }
            }
            session.onFinished = { [weak self] in
                Task { @MainActor in
                    self?.isRecording = false
                    self?.timer?.invalidate()
                    self?.resetAudioLevels()
                    self?.updateStatus()
                }
            }
            session.onAudioLevelsChanged = { [weak self] system, microphone in
                Task { @MainActor in
                    self?.systemAudioLevel = system
                    self?.microphoneAudioLevel = microphone
                }
            }

            let outputURL = try await session.start(options: options)
            self.session = session
            isRecording = true
            setError(nil)
            setStatus(.recording)
            setDetail(.path(outputURL.path))
            startTimer()
        } catch {
            setError(error.localizedDescription)
            setStatus(.startFailed)
        }
    }

    func stopRecording() async {
        guard let session else { return }
        do {
            try await session.stop()
            updateStatus()
            self.session = nil
            isRecording = false
            resetAudioLevels()
            setStatus(.finished)
            timer?.invalidate()
        } catch {
            setError(error.localizedDescription)
            setStatus(.stopFailed)
        }
    }

    private func makeStartOptions() -> StartOptions {
        if recordingMode == .audioOnly {
            return StartOptions(
                display: false,
                outputDirectory: outputDirectory,
                audioOnly: true,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
            )
        }

        switch selection {
        case .display:
            return StartOptions(
                display: true,
                fps: Int32(fps),
                resolutionMode: resolutionMode,
                outputDirectory: outputDirectory,
                includeCursor: includeCursor,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
            )
        case .window(let windowID):
            return StartOptions(
                windowID: windowID,
                fps: Int32(fps),
                resolutionMode: resolutionMode,
                outputDirectory: outputDirectory,
                includeCursor: includeCursor,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
            )
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
    }

    private func updateStatus() {
        guard let status = session?.status() else { return }
        setStatus(isRecording ? .recordingProgress(duration: status.durationText, fileSize: status.fileSizeText) : .finishedSize(status.fileSizeText))
        setDetail(.path(status.outputURL.path))
    }

    private func setStatus(_ value: StatusState) {
        guard statusState != value else { return }
        statusState = value
    }

    private func setDetail(_ value: DetailState) {
        guard detailState != value else { return }
        detailState = value
    }

    private func setError(_ value: String?) {
        guard errorText != value else { return }
        errorText = value
    }

    private func resetAudioLevels() {
        systemAudioLevel = 0
        microphoneAudioLevel = 0
    }
}

struct ContentView: View {
    @StateObject private var model = MeetRecViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeRow
            if model.recordingMode == .video {
                targetPicker
            }
            settings
            actionRow
            statusPanel
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 700, alignment: .topLeading)
    }

    private var modeRow: some View {
        HStack(spacing: 14) {
            Text(model.ui("モード", "Mode"))
                .frame(width: 64, alignment: .leading)
            Picker(model.ui("モード", "Mode"), selection: $model.recordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.title(language: model.language)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRecording)
            .frame(width: 200)

            Spacer()

            Picker(model.ui("言語", "Language"), selection: $model.language) {
                ForEach(InterfaceLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 148)
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(model.ui("録画対象", "Target"))
                    .frame(width: 64, alignment: .leading)
                Picker(model.ui("録画対象", "Target"), selection: $model.selection) {
                    if !model.targets.displays.isEmpty {
                        Text(model.ui("画面全体（Dockなし）", "Entire screen (no Dock)")).tag(TargetChoice.display)
                    }
                    ForEach(model.targets.windows) { window in
                        Text(window.displayTitle)
                            .tag(TargetChoice.window(window.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(model.isRecording)
                .frame(maxWidth: .infinity)
                Button {
                    Task { await model.refreshTargets() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(model.ui("録画対象を更新", "Refresh targets"))
                .disabled(model.isRecording)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.recordingMode == .video {
                HStack(spacing: 14) {
                    Text("FPS")
                        .frame(width: 64, alignment: .leading)
                    Slider(value: $model.fps, in: 5...60, step: 1)
                        .disabled(model.isRecording)
                    Text("\(Int(model.fps))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                HStack(spacing: 14) {
                    Text(model.ui("画質", "Quality"))
                        .frame(width: 64, alignment: .leading)
                    Picker(model.ui("画質", "Quality"), selection: $model.resolutionMode) {
                        Text(model.ui("高画質（Retina）", "High quality (Retina)")).tag(StartOptions.ResolutionMode.retina)
                        Text(model.ui("軽量（半分）", "Lightweight (half)")).tag(StartOptions.ResolutionMode.half)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isRecording)
                    .frame(width: 280)
                }

                Toggle(model.ui("カーソルを録画する", "Record cursor"), isOn: $model.includeCursor)
                    .disabled(model.isRecording)
            }

            Toggle(model.ui("自分の声も録音する", "Record my voice"), isOn: $model.includeMicrophone)
                .disabled(model.isRecording)

            HStack(spacing: 14) {
                Text(model.ui("入力", "Input"))
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: $model.selectedMicrophoneID) {
                    if model.microphones.isEmpty {
                        Text(model.ui("入力ソースなし", "No input source")).tag("")
                    }
                    ForEach(model.microphones) { microphone in
                        Text(microphone.displayTitle).tag(microphone.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(model.isRecording || !model.includeMicrophone || model.microphones.isEmpty)
                Button {
                    model.refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(model.ui("入力ソースを更新", "Refresh input sources"))
                .disabled(model.isRecording)
            }

            audioMeters

            HStack(spacing: 10) {
                Text(model.ui("保存先", "Save to"))
                    .frame(width: 64, alignment: .leading)
                Text(model.outputDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.chooseOutputDirectory()
                } label: {
                    Label(model.ui("選択", "Choose"), systemImage: "folder")
                }
                .disabled(model.isRecording)
            }
        }
    }

    private var audioMeters: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeter(title: model.ui("Mac音声", "Mac audio"), level: model.systemAudioLevel, isActive: model.isRecording)
            LevelMeter(title: model.ui("マイク", "Mic"), level: model.microphoneAudioLevel, isActive: model.isRecording && model.includeMicrophone)
        }
        .padding(.leading, 78)
    }

    private var actionRow: some View {
        HStack {
            Button {
                model.toggleRecording()
            } label: {
                Label(actionTitle, systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(width: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .keyboardShortcut(model.isRecording ? .cancelAction : .defaultAction)

            Spacer()
        }
    }

    private var actionTitle: String {
        if model.isRecording {
            return model.ui("停止", "Stop")
        }
        return model.recordingMode == .audioOnly
            ? model.ui("録音開始", "Start audio")
            : model.ui("録画開始", "Start recording")
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
                .font(.headline)
            Text(model.detailText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            if let errorText = model.errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct LevelMeter: View {
    let title: String
    let level: Double
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 72, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(proxy.size.width * CGFloat(min(max(level, 0), 1)), 2))
                }
            }
            .frame(height: 8)
        }
        .frame(height: 18)
        .opacity(isActive ? 1 : 0.55)
    }

    private var meterColor: Color {
        switch level {
        case 0.82...:
            return .red
        case 0.62..<0.82:
            return .orange
        default:
            return .accentColor
        }
    }
}

@main
struct MeetRecGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MeetRec") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "MeetRec", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        DispatchQueue.main.async {
            NSApplication.shared.windows.forEach { window in
                window.setContentSize(NSSize(width: 748, height: 456))
                window.minSize = window.frame.size
                window.maxSize = window.frame.size
                window.center()
            }
        }
    }
}
