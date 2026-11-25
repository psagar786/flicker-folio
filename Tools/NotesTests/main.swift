import Foundation

let markup = NoteMarkup("## Intro\n\n- **Sagar** and *Aarav*\n- <u>Product</u> [pause]\n***ગુજરાતી***")
precondition(markup.text == "Intro\n\n• Sagar and Aarav\n• Product [pause]\nગુજરાતી")
let rendered = markup.text as NSString
precondition(markup.runs.contains { $0.style.contains(.heading) && rendered.substring(with: $0.range) == "Intro" })
precondition(markup.runs.contains { $0.style.contains(.underline) && rendered.substring(with: $0.range) == "Product" })
precondition(markup.runs.contains { $0.style.contains([.bold, .italic]) && rendered.substring(with: $0.range) == "ગુજરાતી" })
precondition(NoteMarkup("A plain sentence (like this).").text == "A plain sentence (like this).")

let spaced = "## **Hello**\r\n \t\r\n\r\n<u>Surat</u>"
let compact = NoteMarkup(spaced, skipBlankLines: true)
precondition(compact.text == "Hello\nSurat")
precondition(NoteMarkup(spaced).text == "Hello\n \t\n\nSurat")
precondition(compact.runs.contains {
    $0.style.contains(.underline) && (compact.text as NSString).substring(with: $0.range) == "Surat"
})
let sample = Script(title: "Intro", text: "## Hi\n- **Sagar** [pause]", notes: "Private", folder: "Practice")
precondition(sample.wordCount == 2)
let encoder = JSONEncoder()
let decoder = JSONDecoder()
let data = try encoder.encode(sample)
let restored = try decoder.decode(Script.self, from: data)
precondition(restored == sample)
var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
old.removeValue(forKey: "notes")
old.removeValue(forKey: "folder")
let legacy = try decoder.decode(Script.self, from: JSONSerialization.data(withJSONObject: old))
precondition(legacy.text == sample.text && legacy.notes == nil && legacy.folder == nil)

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let store = directory.appendingPathComponent("scripts.json")
let library = ScriptLibrary(fileURL: store, welcome: { sample }, keepsLocal: { _ in true }, cloud: nil)
let copy = library.duplicate(sample.id)!
precondition(copy.text == sample.text && copy.notes == "Private" && copy.folder == "Practice")
library.setFolder("  Demos  ", of: copy.id)
library.setNotes("Reminder", of: copy.id)
library.saveNow()
let loaded = ScriptLibrary(fileURL: store, welcome: { sample }, keepsLocal: { _ in true }, cloud: nil)
precondition(loaded.script(copy.id)?.folder == "Demos" && loaded.script(copy.id)?.notes == "Reminder")

let rtf = directory.appendingPathComponent("Example.rtf")
try #"{\rtf1\ansi Hello \b Sagar\b0\par}"#.write(to: rtf, atomically: true, encoding: .utf8)
let imported = try library.importFile(at: rtf)
let rich = NoteMarkup(imported.text)
precondition(rich.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello Sagar")
precondition(rich.runs.contains { $0.style.contains(.bold) && (rich.text as NSString).substring(with: $0.range) == "Sagar" })
print("Markup, local notes, legacy migration, duplication, and RTF import passed")

let practiceNotes = (1...100).map { index in
    Script(title: "Practice \(index)", text: "Product update \(index)",
           notes: index == 42 ? "Customer retention" : nil, folder: "Practice")
}
precondition(practiceNotes.filter { $0.matchesSearch("  customer RETENTION  ") }.map(\.id) == [practiceNotes[41].id])
precondition(practiceNotes.filter { $0.matchesSearch("Practice 99") }.map(\.id) == [practiceNotes[98].id])

let malformed = directory.appendingPathComponent("malformed.json")
let original = Data("{\"scripts\":[".utf8)
try original.write(to: malformed)
let recovered = ScriptLibrary(fileURL: malformed, welcome: { sample }, keepsLocal: { _ in true }, cloud: nil)
if case .recoveryRequired = recovered.saveState {} else { preconditionFailure("Recovery should block saves") }
let edited = recovered.add(title: "Test edit", text: "In-memory change")
precondition(!recovered.saveNow())
let unchanged = try Data(contentsOf: malformed)
precondition(unchanged == original)
let backup = recovered.preserveLibraryAndSave()!
let backupBytes = try Data(contentsOf: backup)
precondition(backupBytes == original && recovered.saveState == .saved)
let restoredLibrary = ScriptLibrary(fileURL: malformed, welcome: { sample }, keepsLocal: { _ in true }, cloud: nil)
precondition(restoredLibrary.script(edited.id)?.text == "In-memory change")

let blockedParent = directory.appendingPathComponent("blocked")
let retrying = ScriptLibrary(fileURL: blockedParent.appendingPathComponent("scripts.json"),
                             welcome: { sample }, keepsLocal: { _ in true }, cloud: nil)
try Data("File blocks parent directory".utf8).write(to: blockedParent)
let unsaved = retrying.add(title: "Retry fixture", text: "Still in memory")
precondition(!retrying.saveNow())
if case .failed = retrying.saveState {} else { preconditionFailure("Expected save failure") }
precondition(retrying.script(unsaved.id)?.text == "Still in memory" && retrying.hasUnsavedChanges)
try FileManager.default.removeItem(at: blockedParent)
precondition(retrying.saveNow() && !retrying.hasUnsavedChanges)

let unicode = "ગુજરાતી नमस्ते English"
for (name, encoding) in [("Windows", String.Encoding.utf16LittleEndian), ("Classic", .utf16BigEndian)] {
    let url = directory.appendingPathComponent(name + ".txt")
    var encoded = Data(encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
    encoded.append(unicode.data(using: encoding)!)
    try encoded.write(to: url)
    let imported = try library.importFile(at: url)
    precondition(imported.text == unicode)
}
print("Recovery preserves original bytes, failed edits survive retry, and UTF-16LE/BE imports passed")
