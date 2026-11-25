import Foundation
import Combine

/// User preferences, saved in UserDefaults. SwiftUI views and the prompter both observe this.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public static let speedRange: ClosedRange<Double> = 60...300
    public static let fontSizeRange: ClosedRange<Double> = 12...35
    public static let widthRange: ClosedRange<Double> = 15...55
    public static let indianEnglish = "en-IN"
    public static let heightRange: ClosedRange<Double> = 100...600
    /// `voiceLanguage` value that means "detect from the script".
    public static let automaticLanguage = "auto"

    private let defaults = UserDefaults.standard

    /// Reading speed for timed and conversational playback.
    @Published public var speed: Double { didSet { defaults.set(speed, forKey: "wordsPerMinute") } }
    @Published public var readingMode: ReadingMode {
        didSet { defaults.set(readingMode.rawValue, forKey: "readingMode") }
    }
    @Published public var textColor: PromptColor {
        didSet { defaults.set(textColor.rawValue, forKey: "textColor") }
    }
    @Published public var fontStyle: PromptFont {
        didSet { defaults.set(fontStyle.rawValue, forKey: "fontStyle") }
    }
    @Published public var showReadingLine: Bool {
        didSet { defaults.set(showReadingLine, forKey: "showReadingLine") }
    }
    @Published public var voiceSensitivity: Double {
        didSet { defaults.set(voiceSensitivity, forKey: "voiceSensitivity") }
    }
    @Published public var fontSize: Double { didSet { defaults.set(fontSize, forKey: "notchFontSize") } }
    @Published public var width: Double { didSet { defaults.set(width, forKey: "notchPanelWidthPercent") } }
    @Published public var height: Double { didSet { defaults.set(height, forKey: "height") } }
    /// Pause play mode while the mouse is over the prompter.
    @Published public var pauseOnHover: Bool { didSet { defaults.set(pauseOnHover, forKey: "pauseOnScriptHover") } }
    /// Count down 3-2-1 before play mode starts scrolling.
    @Published public var countdown: Bool { didSet { defaults.set(countdown, forKey: "countdown") } }
    @Published public var countdownSound: Bool { didSet { defaults.set(countdownSound, forKey: "countdownSound") } }
    /// A speech locale such as "en-US", or `automaticLanguage`.
    @Published public var voiceLanguage: String { didSet { defaults.set(voiceLanguage, forKey: "preferredVoiceLanguage") } }
    /// Keep the prompter out of screen sharing, screenshots and recordings.
    @Published public var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") }
    }
    /// Camera for recordings (`AVCaptureDevice.uniqueID`); empty means the default camera.
    @Published public var cameraID: String { didSet { defaults.set(cameraID, forKey: "cameraID") } }
    /// Microphone for takes and voice-follow (`AVCaptureDevice.uniqueID`); empty means the system's input.
    @Published public var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    /// What a take records: the camera, the screen, or both, each into its own movie.
    @Published public var recordingMode: RecordingMode { didSet { defaults.set(recordingMode.rawValue, forKey: "recordingMode") } }
    /// Show a small camera preview beside the prompter during a take.
    @Published public var showCameraPreview: Bool { didSet { defaults.set(showCameraPreview, forKey: "showCameraPreview") } }
    /// Save what was said in each take as subtitles next to the movie.
    @Published public var saveTranscripts: Bool { didSet { defaults.set(saveTranscripts, forKey: "saveTranscripts") } }
    /// Fill the rest of the screen during a camera take: a soft light on your face, or black against glare.
    @Published public var screenLight: ScreenLight { didSet { defaults.set(screenLight.rawValue, forKey: "screenLight") } }
    /// Only use speech recognition that runs on this Mac (never Apple's servers).
    public let onDeviceOnly = true
    /// The screen the prompter hangs from (its display UUID); empty means the one with the notch.
    @Published public var display: String { didSet { defaults.set(display, forKey: "display") } }
    /// Show/hide, pause and record shortcuts that work while another app is in front.
    @Published public var globalShortcuts: Bool { didSet { defaults.set(globalShortcuts, forKey: "globalShortcuts") } }
    @Published public var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }

    private init() {
        let d = UserDefaults.standard
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            (d.object(forKey: key) as? Double ?? fallback).clamped(to: range)
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

        readingMode = d.string(forKey: "readingMode").flatMap(ReadingMode.init) ?? .timed
        textColor = d.string(forKey: "textColor").flatMap(PromptColor.init) ?? .white
        fontStyle = d.string(forKey: "fontStyle").flatMap(PromptFont.init) ?? .system
        showReadingLine = flag("showReadingLine", true)
        voiceSensitivity = number("voiceSensitivity", 50, 0...100)
        speed = number("wordsPerMinute", 140, Self.speedRange)
        fontSize = number("notchFontSize", 20, Self.fontSizeRange)
        width = number("notchPanelWidthPercent", 30, Self.widthRange)
        height = number("height", 150, Self.heightRange)
        pauseOnHover = flag("pauseOnScriptHover", false)
        countdown = flag("countdown", true)
        countdownSound = flag("countdownSound", true)
        let savedLanguage = d.string(forKey: "preferredVoiceLanguage") ?? Self.automaticLanguage
        voiceLanguage = savedLanguage.replacingOccurrences(of: "_", with: "-").lowercased() == "en-in"
            ? Self.indianEnglish : savedLanguage
        hideFromScreenSharing = flag("hideFromScreenSharing", true)
        cameraID = d.string(forKey: "cameraID") ?? ""
        microphoneID = d.string(forKey: "microphoneID") ?? ""
        // Before 1.1 there was only "Also record the screen", next to the camera.
        recordingMode = d.string(forKey: "recordingMode").flatMap(RecordingMode.init)
            ?? (flag("recordScreen", false) ? .both : .camera)
        showCameraPreview = flag("showCameraPreview", true)
        saveTranscripts = flag("saveTranscripts", false)
        screenLight = d.string(forKey: "screenLight").flatMap(ScreenLight.init) ?? .off
        display = d.string(forKey: "display") ?? ""
        globalShortcuts = flag("globalShortcuts", true)
        hasSeenWelcome = flag("hasSeenWelcome", false)
    }
}

public enum RecordingMode: String, CaseIterable {
    case camera, screen, both
    public var usesCamera: Bool { self != .screen }
    public var usesScreen: Bool { self != .camera }
}

public enum ScreenLight: String, CaseIterable {
    case off, light, dark
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

public enum ReadingMode: String, CaseIterable {
    case timed, conversational, followWords, sentence

    public var title: String {
        switch self {
        case .timed: "Timed"
        case .conversational: "Conversational"
        case .followWords: "Follow My Words"
        case .sentence: "Sentence by Sentence"
        }
    }
}

public enum PromptColor: String, CaseIterable {
    case white = "White"
    case amber = "Warm Yellow"
    case mint = "Mint"
    case ice = "Ice Blue"
    case rose = "Soft Pink"
}

public enum PromptFont: String, CaseIterable {
    case system = "System Sans"
    case rounded = "Rounded"
    case serif = "Serif"
}
