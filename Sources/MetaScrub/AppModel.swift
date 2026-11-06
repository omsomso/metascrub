import AppKit
import MetaScrubCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Selection: Hashable {
        case cleaner
        case viewerHome
        case file(UUID)
    }

    var selection: Selection? = .cleaner

    // MARK: Cleaner state

    enum CleanState {
        case scanning
        case ready
        case cleaning
        case done(CleanResult)
        case failed(String)
    }

    struct CleanItem: Identifiable {
        let id = UUID()
        var url: URL
        var report: MetadataReport?
        var state: CleanState = .scanning

        /// Embedded fields plus extended attributes, i.e. what Clean will try to remove.
        func removableCount(_ options: CleanOptions) -> Int {
            guard let report else { return 0 }
            // System-managed attributes aren't removable, so they don't count.
            let attributes = options.removeExtendedAttributes ? report.attributeEntries.filter(\.isRemovable).count : 0
            return report.embeddedEntries.count + attributes
        }
    }

    enum DestinationMode: String {
        case overwrite
        case folder
    }

    struct CleanSummary {
        var files: Int
        var removed: Int
        var failed: Int
        var folder: URL?
    }

    var cleanItems: [CleanItem] = []
    var isCleaning = false
    var lastSummary: CleanSummary?
    var destinationMode: DestinationMode {
        didSet { UserDefaults.standard.set(destinationMode.rawValue, forKey: "destinationMode") }
    }
    var outputFolder: URL? {
        didSet { UserDefaults.standard.set(outputFolder?.path, forKey: "outputFolder") }
    }
    var options: CleanOptions {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: "cleanOptions") }
    }

    // MARK: Viewer state

    struct PendingChange: Hashable {
        var sectionID: String
        var key: String
        var label: String
        /// nil means the field is removed.
        var value: String?
        var isNew: Bool
    }

    struct ViewerFile: Identifiable {
        let id = UUID()
        var url: URL
        var report: MetadataReport?
        var thumbnail: NSImage?
        var isLoading = true
        var isSaving = false
        var changes: [String: PendingChange] = [:]
        var saveError: String?
        var saveNotes: [String] = []
        var hasChanges: Bool { !changes.isEmpty }
    }

    var viewerFiles: [ViewerFile] = []
    /// Long, rarely needed sections start collapsed.
    var collapsedSections: Set<String> = ["spotlight", "img.image", "img.png"]

    init() {
        let defaults = UserDefaults.standard
        destinationMode = DestinationMode(rawValue: defaults.string(forKey: "destinationMode") ?? "") ?? .overwrite
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        options = defaults.data(forKey: "cleanOptions").flatMap { try? JSONDecoder().decode(CleanOptions.self, from: $0) } ?? CleanOptions()
    }

    // MARK: Adding files

    /// Files inside dropped folders are added one by one; hidden files and app bundles are skipped.
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { result.append(file) }
                }
            } else if values?.isDirectory != true {
                result.append(url)
            }
        }
        return result
    }

    func addToCleaner(_ urls: [URL]) {
        let expanded = Self.expand(urls)
        let paths = Set(expanded.map { $0.standardizedFileURL.path })
        // Files already listed and finished are read again, so they can be cleaned again after edits.
        for index in cleanItems.indices where paths.contains(cleanItems[index].url.standardizedFileURL.path) {
            switch cleanItems[index].state {
            case .done, .failed:
                cleanItems[index].state = .scanning
                let id = cleanItems[index].id
                Task { await scan(id) }
            default:
                break
            }
        }
        let known = Set(cleanItems.map { $0.url.standardizedFileURL.path })
        let fresh = expanded.filter { !known.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        lastSummary = nil
        for url in fresh {
            let item = CleanItem(url: url)
            cleanItems.append(item)
            Task { await scan(item.id) }
        }
    }

    private func scan(_ id: UUID) async {
        guard let url = cleanItems.first(where: { $0.id == id })?.url else { return }
        let report = await MetadataEngine.inspect(url, includeSpotlight: false)
        guard let index = cleanItems.firstIndex(where: { $0.id == id }) else { return }
        cleanItems[index].report = report
        cleanItems[index].state = .ready
    }

    func removeCleanItem(_ id: UUID) {
        cleanItems.removeAll { $0.id == id }
    }

    func clearCleaner() {
        cleanItems.removeAll()
        lastSummary = nil
    }

    var pendingCleanCount: Int {
        cleanItems.filter { if case .ready = $0.state { return true }; if case .failed = $0.state { return true }; return false }.count
    }

    var totalFoundCount: Int {
        cleanItems.reduce(0) { $0 + $1.removableCount(options) }
    }

    var isScanning: Bool {
        cleanItems.contains { if case .scanning = $0.state { return true }; return false }
    }

    // MARK: Cleaning

    struct Job: Sendable {
        var id: UUID
        var url: URL
        var report: MetadataReport?
        var options: CleanOptions
        var destination: CleanDestination
    }

    func clean() async {
        guard !isCleaning else { return }
        let destination: CleanDestination
        switch destinationMode {
        case .overwrite:
            destination = .overwrite
        case .folder:
            if outputFolder == nil { chooseOutputFolder() }
            guard let outputFolder else { return }
            try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            destination = .folder(outputFolder)
        }
        var jobs: [Job] = []
        for index in cleanItems.indices {
            switch cleanItems[index].state {
            case .ready, .failed:
                cleanItems[index].state = .cleaning
                jobs.append(Job(id: cleanItems[index].id, url: cleanItems[index].url, report: cleanItems[index].report,
                                options: options, destination: destination))
            default:
                break
            }
        }
        guard !jobs.isEmpty else { return }
        isCleaning = true
        var summary = CleanSummary(files: 0, removed: 0, failed: 0, folder: destinationMode == .folder ? outputFolder : nil)
        await withTaskGroup(of: (UUID, Result<CleanResult, Error>).self) { group in
            var next = 0
            func start() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    do {
                        return (job.id, .success(try await MetadataEngine.clean(job.url, options: job.options, destination: job.destination,
                                                                                before: job.report)))
                    } catch {
                        return (job.id, .failure(error))
                    }
                }
            }
            for _ in 0..<3 { start() }
            for await (id, result) in group {
                if let index = cleanItems.firstIndex(where: { $0.id == id }) {
                    switch result {
                    case .success(let outcome):
                        cleanItems[index].state = .done(outcome)
                        summary.files += 1
                        summary.removed += outcome.removedCount
                        refreshViewer(for: cleanItems[index].url)
                    case .failure(let error):
                        cleanItems[index].state = .failed(error.localizedDescription)
                        summary.failed += 1
                    }
                }
                start()
            }
        }
        isCleaning = false
        lastSummary = summary
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Cleaned copies are saved here with their original names."
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    // MARK: Viewer

    func openInViewer(_ urls: [URL]) {
        var firstNew: UUID?
        for url in Self.expand(urls) {
            if let existing = viewerFiles.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                firstNew = firstNew ?? existing.id
                continue
            }
            let file = ViewerFile(url: url)
            viewerFiles.append(file)
            firstNew = firstNew ?? file.id
            Task { await load(file.id) }
        }
        if let firstNew { selection = .file(firstNew) }
    }

    func viewerIndex(_ id: UUID) -> Int? { viewerFiles.firstIndex { $0.id == id } }

    func load(_ id: UUID) async {
        guard let index = viewerIndex(id) else { return }
        viewerFiles[index].isLoading = true
        let url = viewerFiles[index].url
        let report = await MetadataEngine.inspect(url)
        let thumbnail = await Thumbnails.image(for: url, size: 192)
        guard let index = viewerIndex(id) else { return }
        viewerFiles[index].report = report
        viewerFiles[index].thumbnail = thumbnail
        viewerFiles[index].isLoading = false
    }

    /// Reloads the viewer's copy of a file that was cleaned, unless it has unsaved edits.
    private func refreshViewer(for url: URL) {
        for file in viewerFiles where file.url.standardizedFileURL.path == url.standardizedFileURL.path && !file.hasChanges {
            Task { await load(file.id) }
        }
    }

    func closeViewerFile(_ id: UUID) {
        viewerFiles.removeAll { $0.id == id }
        if selection == .file(id) { selection = viewerFiles.last.map { .file($0.id) } ?? .viewerHome }
    }

    func sendToCleaner(_ id: UUID) {
        guard let file = viewerFiles.first(where: { $0.id == id }) else { return }
        addToCleaner([file.url])
        selection = .cleaner
    }

    // MARK: Editing

    static func changeKey(_ sectionID: String, _ key: String) -> String { sectionID + "\u{1F}" + key }

    func displayedValue(_ fileID: UUID, _ sectionID: String, _ entry: MetadataEntry) -> String {
        guard let index = viewerIndex(fileID) else { return entry.value }
        return viewerFiles[index].changes[Self.changeKey(sectionID, entry.key)]?.value ?? entry.value
    }

    func change(_ fileID: UUID, _ sectionID: String, _ key: String) -> PendingChange? {
        viewerIndex(fileID).flatMap { viewerFiles[$0].changes[Self.changeKey(sectionID, key)] }
    }

    func setValue(_ fileID: UUID, _ sectionID: String, _ entry: MetadataEntry, _ value: String) {
        guard let index = viewerIndex(fileID) else { return }
        let key = Self.changeKey(sectionID, entry.key)
        if value == entry.value && viewerFiles[index].changes[key]?.isNew != true {
            viewerFiles[index].changes.removeValue(forKey: key)
        } else {
            let isNew = viewerFiles[index].changes[key]?.isNew ?? false
            viewerFiles[index].changes[key] = PendingChange(sectionID: sectionID, key: entry.key, label: entry.label, value: value, isNew: isNew)
        }
        viewerFiles[index].saveError = nil
    }

    func remove(_ fileID: UUID, _ sectionID: String, _ entry: MetadataEntry) {
        guard let index = viewerIndex(fileID) else { return }
        let key = Self.changeKey(sectionID, entry.key)
        if viewerFiles[index].changes[key]?.isNew == true {
            viewerFiles[index].changes.removeValue(forKey: key)
        } else {
            viewerFiles[index].changes[key] = PendingChange(sectionID: sectionID, key: entry.key, label: entry.label, value: nil, isNew: false)
        }
    }

    func restore(_ fileID: UUID, _ sectionID: String, _ entry: MetadataEntry) {
        guard let index = viewerIndex(fileID) else { return }
        viewerFiles[index].changes.removeValue(forKey: Self.changeKey(sectionID, entry.key))
    }

    func addField(_ fileID: UUID, _ sectionID: String, key: String, label: String) {
        guard let index = viewerIndex(fileID) else { return }
        let changeKey = Self.changeKey(sectionID, key)
        guard viewerFiles[index].changes[changeKey] == nil else { return }
        viewerFiles[index].changes[changeKey] = PendingChange(sectionID: sectionID, key: key, label: label, value: "", isNew: true)
    }

    /// Fields added in the viewer and not saved yet, per section.
    func addedEntries(_ fileID: UUID, _ sectionID: String) -> [MetadataEntry] {
        guard let index = viewerIndex(fileID) else { return [] }
        return viewerFiles[index].changes.values.filter { $0.isNew && $0.sectionID == sectionID }
            .sorted { $0.label < $1.label }
            .map { MetadataEntry(key: $0.key, label: $0.label, value: "", detail: $0.key, editable: true, removable: true, multiline: false) }
    }

    func removeLocation(_ fileID: UUID) {
        guard let index = viewerIndex(fileID), let report = viewerFiles[index].report else { return }
        for section in report.sections where section.kind == .embedded {
            for entry in section.entries where entry.highlight == .location && entry.isRemovable {
                remove(fileID, section.id, entry)
            }
        }
    }

    func revert(_ fileID: UUID) {
        guard let index = viewerIndex(fileID) else { return }
        viewerFiles[index].changes.removeAll()
        viewerFiles[index].saveError = nil
    }

    func edits(_ fileID: UUID) -> [MetadataEdit] {
        guard let index = viewerIndex(fileID) else { return [] }
        return viewerFiles[index].changes.values.compactMap { change in
            if let value = change.value {
                if change.isNew && value.isEmpty { return nil }
                return .set(change.sectionID, change.key, value)
            }
            return .remove(change.sectionID, change.key)
        }
    }

    func save(_ fileID: UUID, as target: URL? = nil) async {
        guard let index = viewerIndex(fileID), !viewerFiles[index].isSaving else { return }
        let url = viewerFiles[index].url
        let edits = edits(fileID)
        viewerFiles[index].isSaving = true
        viewerFiles[index].saveError = nil
        do {
            let notes = try await MetadataEngine.save(edits, for: url, saveAs: target)
            guard let index = viewerIndex(fileID) else { return }
            viewerFiles[index].isSaving = false
            viewerFiles[index].saveNotes = notes
            if let target, target.standardizedFileURL.path != url.standardizedFileURL.path {
                // The original is unchanged; open the new copy next to it.
                viewerFiles[index].changes.removeAll()
                openInViewer([target])
                if let copy = viewerFiles.first(where: { $0.url.standardizedFileURL.path == target.standardizedFileURL.path }) {
                    if let copyIndex = viewerIndex(copy.id) { viewerFiles[copyIndex].saveNotes = notes }
                }
            } else {
                viewerFiles[index].changes.removeAll()
                await load(fileID)
            }
        } catch {
            guard let index = viewerIndex(fileID) else { return }
            viewerFiles[index].isSaving = false
            viewerFiles[index].saveError = error.localizedDescription
        }
    }

    func saveAs(_ fileID: UUID) {
        guard let file = viewerFiles.first(where: { $0.id == fileID }) else { return }
        let panel = NSSavePanel()
        panel.directoryURL = file.url.deletingLastPathComponent()
        let base = file.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = file.url.pathExtension.isEmpty ? "\(base) copy" : "\(base) copy.\(file.url.pathExtension)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await save(fileID, as: url) }
        }
    }

    var selectedFileID: UUID? {
        if case .file(let id) = selection { return id }
        return nil
    }

    var hasUnsavedChanges: Bool { viewerFiles.contains { $0.hasChanges } }

    // MARK: Panels

    enum Target { case cleaner, viewer }

    func chooseFiles(for target: Target) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = target == .cleaner ? "Add" : "Open"
        guard panel.runModal() == .OK else { return }
        switch target {
        case .cleaner:
            addToCleaner(panel.urls)
            selection = .cleaner
        case .viewer:
            openInViewer(panel.urls)
        }
    }
}
