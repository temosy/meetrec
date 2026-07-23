import CoreGraphics
import Foundation
import MeetRecCore

enum Command {
    case list
    case start(StartOptions)
    case stop
    case help
}

@main
enum MeetRec {
    static func main() async {
        do {
            switch try parseCommand(Array(CommandLine.arguments.dropFirst())) {
            case .list:
                try await listTargets()
            case .start(let options):
                try await runRecorder(options: options)
            case .stop:
                try stopRunningRecorder()
                print(t("停止シグナルを送りました。", "Sent stop signal."))
            case .help:
                printHelp()
            }
        } catch {
            fputs("meetrec: \(error.localizedDescription)\n", stderr)
            fputs(t("ヒント: 初回は macOS の「画面とシステムオーディオの収録」許可が必要です。\n", "Tip: macOS Screen & System Audio Recording permission is required the first time.\n"), stderr)
            exit(1)
        }
    }
}

@MainActor
func runRecorder(options: StartOptions) async throws {
    try ensureNotAlreadyRunning()
    let stopSignal = StopSignal()
    let session = RecordingSession()
    var signalSources: [DispatchSourceSignal] = []

    session.onFailure = { error in
        fputs(t("\n録画エラー: \(error.localizedDescription)\n", "\nRecording error: \(error.localizedDescription)\n"), stderr)
        stopSignal.signal()
    }
    session.onFinished = {
        stopSignal.signal()
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signalSources = [SIGINT, SIGTERM].map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            stopSignal.signal()
        }
        source.resume()
        return source
    }

    try writePidFile()

    do {
        let outputURL = try await session.start(options: options)
        let timer = makeStatusTimer(session: session)
        timer.resume()

        print(t("録画開始: \(session.targetDescription)", "Recording started: \(session.targetDescription)"))
        print(t("保存先: \(outputURL.path)", "Save to: \(outputURL.path)"))
        print(t("停止: Ctrl-C または meetrec stop", "Stop: Ctrl-C or meetrec stop"))

        await stopSignal.wait()
        try await session.stop()
        timer.cancel()
        signalSources.forEach { $0.cancel() }
        cleanupPidFile()
        print(t("\n録画終了: \(outputURL.path)", "\nRecording finished: \(outputURL.path)"))
    } catch {
        signalSources.forEach { $0.cancel() }
        cleanupPidFile()
        throw error
    }
}

@MainActor
func makeStatusTimer(session: RecordingSession) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        Task { @MainActor in
            guard let status = session.status() else { return }
            let line = t("\r経過 \(status.durationText) / \(status.fileSizeText)", "\rElapsed \(status.durationText) / \(status.fileSizeText)")
            print(line, terminator: "")
            fflush(stdout)
        }
    }
    return timer
}

func parseCommand(_ arguments: [String]) throws -> Command {
    guard let first = arguments.first else { return .help }

    switch first {
    case "list":
        guard arguments.count == 1 else { throw MeetRecError.usage(t("使い方: meetrec list", "Usage: meetrec list")) }
        return .list
    case "stop":
        guard arguments.count == 1 else { throw MeetRecError.usage(t("使い方: meetrec stop", "Usage: meetrec stop")) }
        return .stop
    case "start":
        return .start(try parseStartOptions(Array(arguments.dropFirst())))
    case "-h", "--help", "help":
        return .help
    default:
        throw MeetRecError.usage(t("未知のコマンドです: \(first)", "Unknown command: \(first)") + "\n\n\(helpText)")
    }
}

func parseStartOptions(_ arguments: [String]) throws -> StartOptions {
    var options = StartOptions()
    var index = 0

    while index < arguments.count {
        let option = arguments[index]
        switch option {
        case "--app":
            options.appName = try value(after: option, in: arguments, at: &index)
        case "--window-id":
            let raw = try value(after: option, in: arguments, at: &index)
            guard let value = UInt32(raw) else {
                throw MeetRecError.usage(t("--window-id には list で表示される数値を指定してください。", "--window-id must be a number shown by meetrec list."))
            }
            options.windowID = CGWindowID(value)
        case "--display":
            options.display = true
        case "--fps":
            let raw = try value(after: option, in: arguments, at: &index)
            guard let fps = Int32(raw), (1...60).contains(fps) else {
                throw MeetRecError.usage(t("--fps は 1 から 60 の整数で指定してください。", "--fps must be an integer from 1 to 60."))
            }
            options.fps = fps
        case "--retina":
            options.resolutionMode = .retina
        case "--half-resolution":
            options.resolutionMode = .half
        case "--audio-only":
            options.audioOnly = true
        case "--out":
            options.outputDirectory = try value(after: option, in: arguments, at: &index)
        case "--show-cursor":
            options.includeCursor = true
        case "--hide-cursor":
            options.includeCursor = false
        case "--include-mic":
            options.includeMicrophone = true
        case "--no-mic":
            options.includeMicrophone = false
            options.microphoneDeviceID = nil
        case "--mic-device-id":
            options.includeMicrophone = true
            options.microphoneDeviceID = try value(after: option, in: arguments, at: &index)
        default:
            throw MeetRecError.usage(t("未知のオプションです: \(option)", "Unknown option: \(option)") + "\n\n\(helpText)")
        }
        index += 1
    }

    let targetCount = [options.display, options.appName != nil, options.windowID != nil].filter { $0 }.count
    if options.audioOnly, targetCount > 0 {
        throw MeetRecError.usage(t("録音のみでは録画対象を指定しないでください。", "Do not choose a video target in audio-only mode."))
    }
    if targetCount > 1 {
        throw MeetRecError.usage(t("録画対象は --display / --app / --window-id のいずれか一つだけ指定してください。", "Choose only one recording target: --display, --app, or --window-id."))
    }
    if targetCount == 0, !options.audioOnly {
        throw MeetRecError.usage(t("録画対象を指定してください。例: meetrec start --app \"Google Chrome\"", "Choose a recording target. Example: meetrec start --app \"Google Chrome\""))
    }

    return options
}

func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
        throw MeetRecError.usage(t("\(option) の値がありません。", "\(option) needs a value."))
    }
    index = valueIndex
    return arguments[valueIndex]
}

func listTargets() async throws {
    let targets = try await loadShareableTargets()

    print("Displays")
    for display in targets.displays {
        print("  display-id=\(display.id)  \(display.width)x\(display.height)  frame=\(display.frameDescription)")
    }

    print("\nWindows")
    for window in targets.windows {
        let title = window.title.isEmpty ? "(no title)" : window.title
        print("  window-id=\(window.id)  app=\"\(window.appName)\"  title=\"\(title)\"  \(window.width)x\(window.height)  bundle=\(window.bundleIdentifier)")
    }

    print("\nMicrophones")
    for microphone in availableMicrophones() {
        print("  mic-device-id=\(microphone.id)  name=\"\(microphone.name)\"")
    }
}

let japaneseHelpText = """
meetrec - Mac の画面とシステム音声を録画する CLI

使い方:
  meetrec list
  meetrec start --app "Google Chrome"
  meetrec start --window-id 12345
  meetrec start --display
  meetrec start --audio-only
  meetrec start --app Safari --fps 60 --out ~/Movies/Meetings
  meetrec stop

オプション:
  --app NAME       アプリ名または bundle identifier で表示中ウィンドウを選ぶ
  --window-id ID   meetrec list に出る window-id を直接指定する
  --display        メインディスプレイ全体を録画する（Dockは除外）
  --fps N          フレームレート。既定値は 60
  --retina         Retina 解像度で録画する（高画質・既定値）
  --half-resolution
                  半分の解像度で録画する（軽量）
  --audio-only     画面を録画せず、Mac音声だけを .m4a に録音する
  --out PATH       出力先ディレクトリ。既定値は ~/Movies/Meetings
  --show-cursor    カーソルを録画する
  --hide-cursor    カーソルを録画しない（既定値）
  --include-mic    自分の声も録音する
  --no-mic         自分の声を録音しない（既定値）
  --mic-device-id ID
                  指定した入力ソースで自分の声を録音する。ID は meetrec list で確認

注意:
  既定ではマイクをキャプチャしません。--include-mic 指定時だけ自分の声も録音します。
  録音のみで自分の声も入れる場合は --audio-only --include-mic を指定してください。
  全画面再生で黒余白を避けたい場合は --display で画面全体を録画してください。Dockとカーソルは既定では録画されません。
"""

let englishHelpText = """
meetrec - Record your Mac screen and system audio

Usage:
  meetrec list
  meetrec start --app "Google Chrome"
  meetrec start --window-id 12345
  meetrec start --display
  meetrec start --audio-only
  meetrec start --app Safari --fps 60 --out ~/Movies/Meetings
  meetrec stop

Options:
  --app NAME       Choose a visible window by app name or bundle identifier
  --window-id ID   Choose a window-id shown by meetrec list
  --display        Record the main display, excluding the Dock
  --fps N          Frame rate. Default is 60
  --retina         Record at Retina resolution. High quality, default
  --half-resolution
                  Record at half resolution. Smaller files
  --audio-only     Record Mac audio to .m4a without screen video
  --out PATH       Output directory. Default is ~/Movies/Meetings
  --show-cursor    Record the cursor
  --hide-cursor    Do not record the cursor. Default
  --include-mic    Record your voice
  --no-mic         Do not record your voice. Default
  --mic-device-id ID
                  Record your voice using the specified input source. IDs are shown by meetrec list

Notes:
  The microphone is off by default. Your voice is recorded only with --include-mic.
  For audio-only with your voice, use --audio-only --include-mic.
  To avoid black margins in full-screen playback, use --display. The Dock and cursor are not recorded by default.
"""

let helpText = t(japaneseHelpText, englishHelpText)

func printHelp() {
    print(helpText)
}
