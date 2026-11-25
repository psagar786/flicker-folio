import AppKit
import SwiftUI
import NotchPrompterKit

/// First-launch welcome: what the app does, the microphone permission, and where the controls are.
struct OnboardingView: View {
    var onFinish: () -> Void

    @ViewState private var page = 0
    @ViewState private var permissionProblem: String?
    @ViewState private var authorized = VoiceListener.isAuthorized
    @ViewState private var asking = false

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            // All pages are laid out on top of each other and only the current one shows, so the
            // window is as tall as the longest page in the current language and never changes size.
            ZStack {
                ForEach(0..<pageCount, id: \.self) { i in
                    pageView(i)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(i == page ? 1 : 0)
                        .allowsHitTesting(i == page)
                        .accessibilityHidden(i != page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 28)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Page \(page + 1) of \(pageCount)", comment: "Onboarding page indicator"))
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                if page < pageCount - 1 {
                    Button("Continue") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Starter Script") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }

    @ViewBuilder private func pageView(_ index: Int) -> some View {
        switch index {
        case 0: welcome
        case 1: voice
        case 2: play
        default: scripts
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Welcome to Flicker Folio").font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Keep your script near the camera for product demos, pitches, video résumés and presentations.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var voice: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
                .frame(height: 70)
            Text("It follows your voice").font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Follow My Words advances when macOS matches spoken words to your script. It needs an available on-device speech language. Timed playback works with no permissions.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Live speech is processed on your Mac. You can choose to save a local video and subtitles when recording.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if authorized {
                Label("Microphone allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(asking ? LocalizedStringKey("Waiting…") : "Allow Microphone and Speech Recognition") {
                    asking = true
                    VoiceListener.requestPermissions { problem in
                        asking = false
                        permissionProblem = problem
                        authorized = problem == nil
                    }
                }
                .controlSize(.large)
                .disabled(asking)
            }
            if let permissionProblem {
                Text(permissionProblem).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }

    private var play: some View {
        VStack(spacing: 18) {
            Text("The controls").font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                row("mic.fill", .red, "Follow My Words", "Match speech to your script. Click a word to re-anchor.")
                row("record.circle", .red, "Record", "Film yourself while you read. Takes go to Movies › Flicker Folio.")
                row("play.fill", .primary, "Timed and Conversational", "Steady WPM, or scroll when you speak and pause in quiet.")
                row("speedometer", .primary, "Pacing", "Change WPM in settings or with Shift and the arrow keys.")
                row("pencil", .primary, "Edit scripts", "Write, paste or import your scripts.")
                row("slider.horizontal.3", .primary, "Settings", "Text size, speed, voice language and more.")
            }
            Text("Drag the edges or corners of the prompter to resize it.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var scripts: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(height: 70)
            Text("Your scripts").font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Write your scripts in the built-in editor, or import text, Markdown and Word files. Everything is saved on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Open the Start Here script for a hands-on walkthrough. Then try a practice script for a product pitch or a video résumé.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint == .primary ? Color.white : tint)
                .frame(width: 34, height: 26)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
