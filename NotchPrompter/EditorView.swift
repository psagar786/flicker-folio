import SwiftUI
import UniformTypeIdentifiers
import NotchPrompterKit

/// A small editor for the script library: a list of scripts on the left, the text on the right.
struct EditorView: View {
    @ObservedObject var library: ScriptLibrary
    @ObservedObject var settings: AppSettings
    var onRead: (Script) -> Void
    var onSettings: () -> Void

    @ViewState private var selection: UUID?
    @ViewState private var importing = false
    @ViewState private var exporting = false
    @ViewState private var exportFormat = ExportFormat.markdown
    @ViewState private var search = ""
    @ViewState private var showingPacing = false
    @ViewState private var folder: String?
    @ViewState private var movingScript: UUID?
    @ViewState private var folderName = ""
    @ViewState private var confirmDelete: UUID?
    @ViewState private var problem: String?
    @FocusState private var textFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search scripts and notes", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search scripts and notes")
                    Menu {
                        Picker("Folder", selection: $folder) {
                            Text("All Scripts").tag(nil as String?)
                            ForEach(folders, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: { Image(systemName: "folder").accessibilityLabel("Filter by folder") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(10)
                List(selection: $selection) {
                ForEach(filteredScripts) { script in
                    ScriptRow(script: script, isActive: script.id == library.activeID)
                        .tag(script.id)
                        .contextMenu {
                            Button("Duplicate") { selection = library.duplicate(script.id)?.id }
                            Button("Move to Folder…") {
                                folderName = script.folder ?? ""
                                movingScript = script.id
                            }
                            Menu("Export") {
                                Button("Markdown…") { export(script, as: .markdown) }
                                Button("Plain Text…") { export(script, as: .plain) }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { confirmDelete = script.id }
                        }
                }
                }
                if filteredScripts.isEmpty {
                    Text("No matching scripts").font(.callout).foregroundStyle(.secondary).padding(12)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 330)
            .toolbar {
                ToolbarItem {
                    Button { newScript() } label: { Label("New Script", systemImage: "square.and.pencil") }
                        .help("New script (⌘N)")
                }
            }
            .onDeleteCommand { if let selection { confirmDelete = selection } }
        } detail: {
            if let id = selection, let script = library.script(id) {
                ScriptEditor(library: library, settings: settings, script: script, textFocused: $textFocused)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Script Selected", systemImage: "doc.text")
                } actions: {
                    Button("New Script") { newScript() }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import a text, Markdown, Word or RTF file")
                Button(action: onSettings) {
                    Label("Pacing Settings", systemImage: "slider.horizontal.3")
                }
                Menu {
                    if let script = selectedScript {
                        Button("Export Markdown…") { export(script, as: .markdown) }
                        Button("Export Plain Text…") { export(script, as: .plain) }
                        Button("Move to Folder…") { folderName = script.folder ?? ""; movingScript = script.id }
                    }
                } label: {
                    Label("Script Actions", systemImage: "ellipsis.circle")
                }
                Button { showingPacing.toggle() } label: {
                    Label(settings.readingMode.title, systemImage: "speedometer")
                }
                .help("Change pace and words per minute")
                .popover(isPresented: $showingPacing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Pacing mode", selection: $settings.readingMode) {
                            ForEach(ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        PacingSpeedSlider(settings: settings)
                        if settings.readingMode == .followWords {
                            Text("Follow My Words uses your speaking pace. WPM applies to the timed modes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(width: 290)
                }
                Button(action: read) {
                    Label(settings.readingMode == .followWords ? "Start Speech Follow" : "Start Auto-scroll",
                          systemImage: settings.readingMode == .followWords ? "mic" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Show this script below the camera using the selected pacing")
                .disabled((selectedScript?.wordCount ?? 0) == 0)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { selection = selection ?? library.activeID ?? library.scripts.first?.id }
        .onReceive(NotificationCenter.default.publisher(for: .selectStarterScript)) { notification in
            guard let id = notification.object as? UUID else { return }
            search = ""
            folder = nil
            selection = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .newScript)) { _ in newScript() }
        .onReceive(NotificationCenter.default.publisher(for: .importScript)) { _ in importing = true }
        .onChange(of: library.scripts.map(\.id)) { _, ids in
            if let s = selection, !ids.contains(s) { selection = library.activeID ?? ids.first }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ScriptLibrary.importTypes,
                      allowsMultipleSelection: true) { result in
            do {
                search = ""
                folder = nil
                var failed: [String] = []
                for url in try result.get() {
                    do { selection = try library.importFile(at: url).id }
                    catch { failed.append(url.lastPathComponent) }
                }
                if !failed.isEmpty { problem = "Couldn’t import " + failed.joined(separator: ", ") }
            } catch {
                problem = String(localized: "That file couldn't be read. Try saving it as plain text or Word first.")
            }
        }
        .fileExporter(isPresented: $exporting, document: PlainTextDocument(text: exportText),
                      contentType: exportFormat.contentType, defaultFilename: selectedScript?.displayTitle
                          ?? String(localized: "Script", comment: "Default file name when exporting a script")) { result in
            if case .failure = result { problem = String(localized: "The script couldn't be saved there.") }
        }
        .confirmationDialog("Delete “\(confirmDelete.flatMap(library.script)?.displayTitle ?? "")”?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete { library.delete(id) }
                confirmDelete = nil
            }
        } message: {
            Text("You can't undo this.")
        }
        .alert("Move to Folder", isPresented: Binding(get: { movingScript != nil }, set: { if !$0 { movingScript = nil } })) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { movingScript = nil }
            Button("Move") {
                if let id = movingScript {
                    library.setFolder(folderName, of: id)
                    folder = nil
                }
                movingScript = nil
            }
        } message: {
            Text("Enter a folder name or leave it blank to remove the script from its folder.")
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {}
    }

    private enum ExportFormat {
        case markdown, plain
        var contentType: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .plain: .plainText
            }
        }
    }

    private var exportText: String {
        guard let script = selectedScript else { return "" }
        return exportFormat == .markdown ? script.text : NoteMarkup(script.text).text
    }

    private var folders: [String] {
        Set(library.scripts.compactMap(\.folder)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredScripts: [Script] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.scripts.filter { script in
            (folder == nil || script.folder == folder) && script.matchesSearch(query)
        }
    }

    private func export(_ script: Script, as format: ExportFormat) {
        selection = script.id
        exportFormat = format
        exporting = true
    }

    private var selectedScript: Script? { selection.flatMap(library.script) }

    private func newScript() {
        search = ""
        selection = library.add(folder: folder).id
        DispatchQueue.main.async { textFocused = true }
    }

    private func read() {
        guard let script = selectedScript else { return }
        onRead(script)
    }
}

private struct ScriptRow: View {
    let script: Script
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.displayTitle).font(.headline).lineLimit(1)
                Text(script.text.isEmpty ? String(localized: "Empty", comment: "Preview of a script without text")
                                          : NoteMarkup(script.text).text.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .foregroundStyle(.tint)
                    .help("Shown in the prompter")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ScriptEditor: View {
    @ObservedObject var library: ScriptLibrary
    @ObservedObject var settings: AppSettings
    let script: Script
    var textFocused: FocusState<Bool>.Binding
    @ViewState private var title = ""
    @ViewState private var text = ""
    @ViewState private var notes = ""
    @ViewState private var tab = EditingTab.script
    @ViewState private var selection: TextSelection?

    private enum EditingTab: String, CaseIterable { case script = "Script", preview = "Preview", notes = "Private Notes" }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title, prompt: Text("Untitled"))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .onChange(of: title) { _, new in library.setTitle(new, of: script.id) }
            Divider().padding(.horizontal, 16)
            HStack {
                Picker("Editor view", selection: $tab) {
                    ForEach(EditingTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
                if let folder = script.folder {
                    Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if tab == .script {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text, selection: $selection)
                        .accessibilityLabel("Script")
                        .font(.system(size: 15)).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .focused(textFocused)
                        .onChange(of: text) { _, new in library.setText(new, of: script.id) }
                    if text.isEmpty {
                        Text("Write or paste your script…").foregroundStyle(.secondary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 5)
            } else if tab == .preview {
                ScrollView {
                    Text(preview).font(.body).lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Private notes stay in the editor. The prompter reads the Script tab.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .accessibilityLabel("Private notes")
                        .font(.system(size: 15)).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .onChange(of: notes) { _, new in library.setNotes(new, of: script.id) }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            if tab != .preview {
                Divider()
                HStack(spacing: 12) {
                    if tab == .script {
                        formatButton("Bold", icon: "bold", prefix: "**", suffix: "**")
                        formatButton("Italic", icon: "italic", prefix: "*", suffix: "*")
                        formatButton("Underline", icon: "underline", prefix: "<u>", suffix: "</u>")
                        formatButton("Heading", icon: "textformat.size", prefix: "## ", suffix: "")
                        formatButton("Bullet list", icon: "list.bullet", prefix: "- ", suffix: "")
                        Divider().frame(height: 14)
                    }
                    PacingSpeedSlider(settings: settings)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            Divider()
            HStack {
                HStack(spacing: 5) {
                    Text("\(script.wordCount) words", comment: "Word count below the script editor")
                    Text(verbatim: "·")
                    Text("about \(script.readingTime(at: settings.speed)) to read",
                         comment: "Below the script editor; the time is formatted by the system, e.g. “1 min, 20 sec”")
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                switch library.saveState {
                case .saved: Text("Saved automatically").lineLimit(1)
                case .pending: Text("Saving…").lineLimit(1)
                case .failed(let message):
                    Button("Retry Save") { library.saveNow() }
                        .help(message)
                case .recoveryRequired:
                    Text("Recovery required").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            switch library.saveState {
            case .failed(let message):
                Label("Edits are unsaved. \(message)", systemImage: "exclamationmark.triangle")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.bar)
            case .recoveryRequired(let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Preserve Original and Save") {
                        if let backup = library.preserveLibraryAndSave() {
                            NSWorkspace.shared.activateFileViewerSelecting([backup])
                        }
                    }
                }
                .font(.callout).padding(10).background(.bar)
            default: EmptyView()
            }
        }
        .navigationTitle(script.displayTitle)
        .onAppear {
            title = script.title
            text = script.text
            notes = script.notes ?? ""
        }
        // Changes from iCloud or the scripts folder, made while the script is open.
        .onChange(of: script.title) { _, new in if new != title { title = new } }
        .onChange(of: script.text) { _, new in if new != text { text = new } }
    }

    private var preview: AttributedString {
        let markup = NoteMarkup(text)
        var result = AttributedString(markup.text)
        for run in markup.runs {
            guard let plainRange = Range(run.range, in: markup.text),
                  let lower = AttributedString.Index(plainRange.lowerBound, within: result),
                  let upper = AttributedString.Index(plainRange.upperBound, within: result)
            else { continue }
            let range = lower..<upper
            if run.style.contains(.heading) { result[range].font = .title2.bold() }
            var traits: InlinePresentationIntent = []
            if run.style.contains(.bold) { traits.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { traits.insert(.emphasized) }
            if !traits.isEmpty { result[range].inlinePresentationIntent = traits }
            if run.style.contains(.underline) { result[range].underlineStyle = .single }
        }
        return result
    }

    private func formatButton(_ label: String, icon: String, prefix: String, suffix: String) -> some View {
        Button {
            let range: Range<String.Index>
            if let selection, case let .selection(selected) = selection.indices { range = selected }
            else { range = text.endIndex..<text.endIndex }
            let selected = String(text[range])
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])
            let startOffset: Int
            let endOffset: Int
            if suffix.isEmpty {
                let lineStart = before.lastIndex(of: "\n").map { before.index(after: $0) } ?? before.startIndex
                let leading = String(before[..<lineStart])
                let lines = String(before[lineStart...]) + selected
                let formatted = lines.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { prefix + $0 }.joined(separator: "\n")
                text = leading + formatted + after
                startOffset = leading.count + formatted.count
                endOffset = startOffset
            } else {
                text = before + prefix + selected + suffix + after
                startOffset = before.count + prefix.count
                endOffset = startOffset + selected.count
            }
            let start = text.index(text.startIndex, offsetBy: startOffset)
            let end = text.index(text.startIndex, offsetBy: endOffset)
            selection = TextSelection(range: start..<end)
            textFocused.wrappedValue = true
        } label: { Image(systemName: icon) }
        .help(label).accessibilityLabel(label)
    }

}

struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, UTType(filenameExtension: "md") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension Notification.Name {
    static let newScript = Notification.Name("NotchPrompter.newScript")
    static let importScript = Notification.Name("NotchPrompter.importScript")
}
