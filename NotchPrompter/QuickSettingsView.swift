import SwiftUI
import NotchPrompterKit

struct PromptScaleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let detail: String
    var percentage: Int { Int((value / range.upperBound * 100).rounded()) }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: 1)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(percentage) percent, \(detail)")
                Text("\(percentage)%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
        }
        .help(detail)
    }
}

struct QuickSettingsView: View {
    @ObservedObject var settings: AppSettings
    let openAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Pacing", selection: $settings.readingMode) {
                ForEach(ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.readingMode == .followWords {
                Text("Follow My Words uses your speaking pace.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                PacingSpeedSlider(settings: settings)
            }
            PromptScaleSlider(title: "Text size", value: $settings.fontSize, range: AppSettings.fontSizeRange,
                              detail: "\(Int(settings.fontSize)) pt. Maximum 35 pt.")
            PromptScaleSlider(title: "Panel width", value: $settings.width, range: AppSettings.widthRange,
                              detail: "\(Int(settings.width))% of the display. Maximum 55%.")
            Toggle("3–2–1 countdown", isOn: $settings.countdown)
            if settings.countdown { Toggle("Countdown sound", isOn: $settings.countdownSound) }
            Divider()
            Button("More Settings…", action: openAll)
        }
        .padding(18)
        .frame(width: 360)
    }
}

struct ScriptSwitcherView: View {
    @ObservedObject var library: ScriptLibrary
    let start: (Script) -> Void
    @ViewState private var search = ""
    @ViewState private var selection: UUID?
    @FocusState private var searchFocused: Bool

    private var matches: [Script] { library.scripts.filter { $0.matchesSearch(search) } }
    private var selected: Script? { matches.first { $0.id == selection } ?? matches.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search scripts and notes", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            List(selection: $selection) {
                ForEach(matches) { script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.displayTitle)
                        if let folder = script.folder {
                            Text(folder).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(script.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if matches.isEmpty { Text("No matching scripts").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Start Selected Script") {
                    if let selected { start(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((selected?.wordCount ?? 0) == 0)
            }
        }
        .padding(16)
        .frame(width: 420, height: 330)
        .onAppear { selection = library.activeID; searchFocused = true }
        .onChange(of: search) { _, _ in
            if !matches.contains(where: { $0.id == selection }) { selection = matches.first?.id }
        }
    }
}
