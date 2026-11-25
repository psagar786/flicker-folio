import Combine
import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public struct Script: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var title: String
    public var text: String
    public var modified = Date()
    public var notes: String?
    public var folder: String?

    public init(title: String, text: String, notes: String? = nil, folder: String? = nil) {
        self.title = title
        self.text = text
        self.notes = notes
        self.folder = folder
    }

    /// Counts words the way the language does, so Japanese and Chinese, with no spaces, count right too.
    public var wordCount: Int {
        var matcher = VoiceMatcher()
        matcher.setText(NoteMarkup(text).text)
        return matcher.words.count
    }

    /// About how long the script takes to read aloud, at 150 words a minute, e.g. "1 min, 20 sec".
    public func readingTime(at speed: Double = 150) -> String {
        let count = wordCount
        let seconds = Int((Double(count) / max(1, speed) * 60).rounded())
        let shown = seconds < 60 ? max(seconds, count > 0 ? 1 : 0) : seconds
        return Duration.seconds(shown).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    public func matchesSearch(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || [displayTitle, text, notes ?? "", folder ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "Untitled", comment: "Name of a script without a title") : title
    }
}

/// All the user's scripts, stored as JSON in the app's Application Support folder, and kept the
/// same on the user's Macs and iPhones through iCloud.
public final class ScriptLibrary: ObservableObject {
    public enum SaveState: Equatable {
        case saved, pending, failed(String), recoveryRequired(String)
    }

    @Published public private(set) var scripts: [Script] = []
    @Published public private(set) var saveState: SaveState = .saved
    public private(set) var hasUnsavedChanges = false
    private var recoveryRequired = false
    /// The script shown in the prompter.
    @Published public var activeID: UUID? { didSet { scheduleSave() } }

    private struct Stored: Codable {
        var scripts: [Script]
        var activeID: UUID?
    }

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?
    private let cloud: KeyValueCloud?
    private let keepsLocal: (Script) -> Bool
    private var cloudObserver: NSObjectProtocol?

    /// `welcome` makes the practice script for a first launch, in the app's language.
    /// `keepsLocal` picks the scripts that stay on this device: the unchanged practice script,
    /// which each app has in its own words. `syncs` is false for demos and screenshots, so they
    /// never reach the user's iCloud.
    public convenience init(welcome: () -> Script, keepsLocal: @escaping (Script) -> Bool = { _ in false },
                            syncs: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.init(fileURL: support.appendingPathComponent("scripts.json"), welcome: welcome, keepsLocal: keepsLocal,
                  cloud: syncs ? NSUbiquitousKeyValueStore.default : nil)
    }

    init(fileURL: URL, welcome: () -> Script, keepsLocal: @escaping (Script) -> Bool, cloud: KeyValueCloud?) {
        self.fileURL = fileURL
        self.keepsLocal = keepsLocal
        self.cloud = cloud

        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: fileURL))
            scripts = stored.scripts
            activeID = stored.activeID
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) {
            // A missing file is a new library.
        } catch {
            recoveryRequired = true
            saveState = .recoveryRequired("The existing library could not be read. Preserve it before saving a replacement.")
        }
        if scripts.isEmpty {
            // The practice script is also available in memory while recovery is pending.
            let first = welcome()
            scripts = [first]
            activeID = first.id
        }
        if active == nil { activeID = scripts.first?.id }

        if let cloud {
            cloudObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud as AnyObject, queue: .main
            ) { [weak self] _ in self?.cloudChanged() }
            cloud.synchronize()
            cloudChanged()
            cloudPush()   // scripts from before sync was turned on
        }
    }

    deinit {
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    public var active: Script? { scripts.first { $0.id == activeID } }

    public func script(_ id: UUID) -> Script? { scripts.first { $0.id == id } }

    // MARK: Editing

    @discardableResult
    public func add(title: String = "", text: String = "", notes: String? = nil, folder: String? = nil) -> Script {
        let script = Script(title: title, text: text, notes: notes, folder: folder)
        scripts.insert(script, at: 0)
        scheduleSave()
        return script
    }

    public func setText(_ text: String, of id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].text != text else { return }
        scripts[i].text = text
        scripts[i].modified = Date()
        scheduleSave()
    }

    public func setTitle(_ title: String, of id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].title != title else { return }
        scripts[i].title = title
        scripts[i].modified = Date()
        scheduleSave()
    }

    public func setNotes(_ notes: String, of id: UUID) {
        let value: String? = notes.isEmpty ? nil : notes
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].notes != value else { return }
        scripts[i].notes = value
        scripts[i].modified = Date()
        scheduleSave()
    }

    public func setFolder(_ folder: String?, of id: UUID) {
        let cleaned = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.flatMap { $0.isEmpty ? nil : $0 }
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].folder != value else { return }
        scripts[i].folder = value
        scripts[i].modified = Date()
        scheduleSave()
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> Script? {
        guard let original = script(id) else { return nil }
        return add(title: String(localized: "\(original.displayTitle) copy", 
                                 comment: "Title of a duplicated script"),
                   text: original.text, notes: original.notes, folder: original.folder)
    }

    public func delete(_ id: UUID) {
        if let script = script(id), !keepsLocal(script) { cloudDelete(id) }
        scripts.removeAll { $0.id == id }
        if scripts.isEmpty { add() }
        if activeID == id { activeID = scripts.first?.id }
        scheduleSave()
    }

    // MARK: Files

    #if os(macOS)
    /// File types that can be imported: plain text, Markdown, RTF, Word and HTML.
    public static let importTypes: [UTType] = [.plainText, .text, .rtf, .rtfd, .html,
                                               UTType(filenameExtension: "md") ?? .plainText,
                                               UTType(filenameExtension: "docx") ?? .data,
                                               UTType(filenameExtension: "doc") ?? .data,
                                               UTType(filenameExtension: "odt") ?? .data]
    #else
    /// File types that can be imported: plain text, Markdown, RTF and HTML. iOS can't read Word files.
    public static let importTypes: [UTType] = [.plainText, .text, .rtf, .rtfd, .html,
                                               UTType(filenameExtension: "md") ?? .plainText]
    #endif

    /// Read a document as plain text and add it to the library. With `replacingSameTitle`, the
    /// newest script named like the file gets the new text instead and moves to the top, so opening
    /// an edited file again doesn't add a copy.
    public func importFile(at url: URL, replacingSameTitle: Bool = false) throws -> Script {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let text: String
        if ["txt", "md", "markdown", "text", ""].contains(ext) {
            let data = try Data(contentsOf: url)
            let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            guard let decoded = String(data: data, encoding: isUTF16 ? .utf16 : .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = decoded
        } else {
            let document = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            #if os(macOS)
            let source = document.string as NSString
            var formatted = ""
            document.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
                let value = source.substring(with: range)
                let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits
                let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
                let marker = (traits?.contains(.bold) == true ? "**" : "") + (traits?.contains(.italic) == true ? "*" : "")
                formatted += value.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    guard let start = line.firstIndex(where: { !$0.isWhitespace }),
                          let end = line.lastIndex(where: { !$0.isWhitespace })
                    else { return String(line) }
                    let body = line[start...end]
                    let marked = marker + body + marker
                    let run = underline ? "<u>" + marked + "</u>" : marked
                    return String(line[..<start]) + run + line[line.index(after: end)...]
                }.joined(separator: "\n")
            }
            text = formatted
            #else
            text = document.string
            #endif
        }
        return importText(title: url.deletingPathExtension().lastPathComponent, text: text,
                          replacingSameTitle: replacingSameTitle)
    }

    /// Add a script, or with `replacingSameTitle` give the newest script with that title the new
    /// text and move it to the top. It keeps its id, so other devices see an update, not a copy.
    public func importText(title: String, text: String, replacingSameTitle: Bool = false) -> Script {
        if replacingSameTitle, let i = scripts.indices.filter({ scripts[$0].title == title })
            .max(by: { scripts[$0].modified < scripts[$1].modified }) {
            var script = scripts.remove(at: i)
            if script.text != text {
                script.text = text
                script.modified = Date()
            }
            scripts.insert(script, at: 0)
            scheduleSave()
            return script
        }
        return add(title: title, text: text)
    }

    public func export(_ id: UUID, to url: URL) throws {
        guard let script = script(id) else { return }
        try script.text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Saving

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveWork?.cancel()
        guard !recoveryRequired else { return }
        saveState = .pending
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    public func saveNow() -> Bool {
        saveWork?.cancel()
        guard writeFile() else { return false }
        cloudPush()
        return true
    }

    /// Preserve the original byte-for-byte before allowing a replacement.
    @discardableResult
    public func preserveLibraryAndSave() -> URL? {
        guard recoveryRequired else { return nil }
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("scripts-recovery-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
        } catch {
            saveState = .recoveryRequired("Could not preserve the original library. \(error.localizedDescription)")
            return nil
        }
        recoveryRequired = false
        saveNow()
        return backup
    }

    @discardableResult
    private func writeFile() -> Bool {
        guard !recoveryRequired else { return false }
        do {
            let data = try JSONEncoder().encode(Stored(scripts: scripts, activeID: activeID))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            hasUnsavedChanges = false
            saveState = .saved
            return true
        } catch {
            hasUnsavedChanges = true
            saveState = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: iCloud
    //
    // Each script is one key in iCloud key-value storage, holding the script as JSON. A deleted
    // script leaves its ID and the time in `deleted`, so other devices delete it too. When two
    // devices change the same script, the later change wins.

    private static let scriptPrefix = "script."
    private static let deletedKey = "deleted"
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // the same script always gives the same data
        return encoder
    }()

    private var cloudDeleted: [String: Date] {
        guard let data = cloud?.data(forKey: Self.deletedKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    /// Take in what other devices changed.
    func cloudChanged() {
        guard let cloud else { return }
        let deleted = cloudDeleted
        var changed = false
        for key in cloud.keys where key.hasPrefix(Self.scriptPrefix) {
            guard let data = cloud.data(forKey: key),
                  let remote = try? JSONDecoder().decode(Script.self, from: data) else { continue }
            if let when = deleted[remote.id.uuidString], when >= remote.modified { continue }
            if let i = scripts.firstIndex(where: { $0.id == remote.id }) {
                guard remote.modified > scripts[i].modified else { continue }
                scripts[i] = remote
            } else {
                // Newest first, like scripts made here.
                scripts.insert(remote, at: scripts.firstIndex { $0.modified < remote.modified } ?? scripts.endIndex)
            }
            changed = true
        }
        for (id, when) in deleted {
            guard let uuid = UUID(uuidString: id), let i = scripts.firstIndex(where: { $0.id == uuid }),
                  scripts[i].modified <= when, !keepsLocal(scripts[i]) else { continue }
            scripts.remove(at: i)
            changed = true
        }
        guard changed else { return }
        if scripts.isEmpty { scripts = [Script(title: "", text: "")] }
        if active == nil { activeID = scripts.first?.id }
        writeFile()
    }

    /// Send the scripts that changed here.
    private func cloudPush() {
        guard let cloud else { return }
        for script in scripts where !keepsLocal(script) {
            let key = Self.scriptPrefix + script.id.uuidString
            guard let data = try? Self.encoder.encode(script), cloud.data(forKey: key) != data else { continue }
            cloud.store(data, forKey: key)
        }
    }

    private func cloudDelete(_ id: UUID) {
        guard let cloud else { return }
        var deleted = cloudDeleted
        deleted[id.uuidString] = Date()
        if let data = try? JSONEncoder().encode(deleted) { cloud.store(data, forKey: Self.deletedKey) }
        cloud.store(nil, forKey: Self.scriptPrefix + id.uuidString)
    }
}

/// The part of iCloud key-value storage the library uses. Tests use one in memory.
protocol KeyValueCloud: AnyObject {
    var keys: [String] { get }
    func data(forKey key: String) -> Data?
    /// nil removes the key.
    func store(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueCloud {
    var keys: [String] { Array(dictionaryRepresentation.keys) }
    func store(_ data: Data?, forKey key: String) {
        if let data { set(data, forKey: key) } else { removeObject(forKey: key) }
    }
}
