import SwiftUI
import NotchPrompterKit

private final class VoiceCheck: ObservableObject {
    static let paragraph = """
    Hello, my name is Sagar. I’m speaking from Surat, Gujarat.

    Today I’ll share a short product update.
    """
    @Published var status = "Ready to listen"
    @Published var transcript = ""
    @Published var matched = 0
    @Published var active = false
    private let voice = VoiceListener()
    private var matcher = VoiceMatcher()
    var total: Int { matcher.words.count }

    init() {
        matcher.setText(Self.paragraph)
        voice.onWords = { [weak self] task, words in
            guard let self else { return }
            transcript = words.joined(separator: " ")
            matcher.follow(words, task: task)
            matched = matcher.cursor
        }
        voice.onStatus = { [weak self] in self?.status = $0 }
        voice.onStopped = { [weak self] in self?.active = false }
        voice.onPermissionProblem = { [weak self] message, _ in self?.status = message }
        voice.onNeedsDictation = { [weak self] in
            self?.status = "Turn on Dictation in System Settings → Keyboard and retry."
        }
    }

    func start(locale: String, inputDeviceUID: String) {
        transcript = ""
        matched = 0
        matcher = VoiceMatcher()
        matcher.setText(Self.paragraph)
        matcher.numberLocale = locale
        voice.inputDeviceUID = inputDeviceUID
        voice.hints = ["Sagar", "Surat", "Gujarat"]
        status = "Starting on-device recognition…"
        active = true
        voice.start(locale: locale)
    }

    func stop() {
        voice.stop()
        active = false
        status = "Stopped"
    }
}

struct VoiceCheckView: View {
    let locale: String
    let inputDeviceUID: String
    let prepare: () -> Bool
    @StateObject private var check = VoiceCheck()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test My Voice").font(.title2.bold())
            Text("Read this sample aloud and compare it with what your Mac heard.")
                .foregroundStyle(.secondary)
            Text(VoiceCheck.paragraph).textSelection(.enabled)
            Divider()
            LabeledContent("Recognition", value: check.status)
            LabeledContent("Script progress", value: "\(check.matched) of \(check.total) words")
            ScrollView {
                Text(check.transcript.isEmpty ? "Recognized words appear here." : check.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60)
            HStack {
                Button(check.active ? "Stop Listening" : "Start Listening") {
                    if check.active { check.stop() }
                    else if prepare() { check.start(locale: locale, inputDeviceUID: inputDeviceUID) }
                    else { check.status = "Stop recording before starting the voice check." }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 470)
        .onDisappear { check.stop() }
    }
}
