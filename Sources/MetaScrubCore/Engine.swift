import Foundation
import UniformTypeIdentifiers

/// What a format handler found inside a file. The engine adds the file-system sections.
struct FormatReport {
    var format: String
    var facts: [Fact] = []
    var sections: [MetadataSection] = []
    var location: GeoPoint?
    var canEdit = false
    var canClean = false
    var notes: [String] = []
}

/// Reads, cleans and edits the metadata of one family of file formats.
protocol FormatHandler: Sendable {
    func read(_ url: URL) async throws -> FormatReport
    /// Writes a copy of `source` without embedded metadata to `destination`. Returns notes for the user.
    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String]
    /// Writes a copy of `source` with `edits` applied to `destination`. Returns notes for the user.
    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String]
}

extension FormatHandler {
    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        throw MetadataError.unsupported("Cleaning isn't supported for this format.")
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        throw MetadataError.unsupported("Editing isn't supported for this format.")
    }
}

public enum MetadataEngine {
    static func handler(for url: URL) -> FormatHandler? {
        switch FileFormat.detect(url) {
        case .jpeg, .png, .gif, .webp, .heif, .tiff, .otherImage:
            return ImageHandler(format: FileFormat.detect(url))
        case .mp3: return MP3Handler()
        case .flac: return FLACHandler()
        case .wav: return ChunkAudioHandler(kind: .wav)
        case .aiff: return ChunkAudioHandler(kind: .aiff)
        case .mpeg4, .otherMedia: return MediaHandler()
        case .pdf: return PDFHandler()
        case .office: return OfficeHandler(kind: .ooxml)
        case .openDocument: return OfficeHandler(kind: .openDocument)
        case .unknown: return nil
        }
    }

    /// Reads everything MetaScrub can see about a file. Never throws: read problems become notes.
    public static func inspect(_ url: URL, includeSpotlight: Bool = true) async -> MetadataReport {
        let kind = url.typeIdentifier?.localizedDescription ?? "File"
        var report: MetadataReport
        if let handler = handler(for: url) {
            do {
                let found = try await handler.read(url)
                report = MetadataReport(url: url, format: found.format, facts: found.facts, sections: found.sections, location: found.location,
                                        canEdit: found.canEdit, canClean: found.canClean, notes: found.notes)
            } catch {
                report = MetadataReport(url: url, format: kind.capitalizedFirst,
                                        notes: ["Couldn't read the metadata inside this file: \(error.localizedDescription)"])
            }
        } else {
            report = MetadataReport(url: url, format: kind.capitalizedFirst,
                                    notes: ["MetaScrub doesn't read metadata stored inside this kind of file. It shows the file-system details, and Clean removes the extended attributes."])
        }
        report.sections.removeAll { [.embedded, .technical, .derived].contains($0.kind) && $0.entries.isEmpty && !$0.canAddFields }
        report.sections.append(FileSystemMetadata.fileSection(url))
        let attributes = FileSystemMetadata.attributesSection(url)
        if !attributes.entries.isEmpty { report.sections.append(attributes) }
        if includeSpotlight, let spotlight = FileSystemMetadata.spotlightSection(url) { report.sections.append(spotlight) }
        return report
    }

    /// Writes a copy of `url` without metadata, either over the original or into a folder.
    public static func clean(_ url: URL, options: CleanOptions, destination: CleanDestination,
                             before knownReport: MetadataReport? = nil) async throws -> CleanResult {
        let before: MetadataReport
        if let knownReport {
            before = knownReport
        } else {
            before = await inspect(url, includeSpotlight: false)
        }
        let originalDates = FileOps.dates(of: url)
        let folder: URL
        switch destination {
        case .overwrite: folder = url.deletingLastPathComponent()
        case .folder(let target): folder = target
        }
        let scratch = try FileOps.scratchFolder(near: folder)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(url.lastPathComponent)

        var notes: [String] = []
        if before.canClean, let handler = handler(for: url) {
            notes += try await handler.clean(url, to: temporary, options: options)
        } else {
            guard copyfile(url.path, temporary.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw MetadataError.writeFailed("Could not copy \(url.lastPathComponent).")
            }
            notes.append(before.embeddedEntries.isEmpty
                         ? "Only file-system metadata could be removed from this kind of file."
                         : "Metadata inside this kind of file can't be removed yet; only file-system metadata was cleaned.")
        }
        FileOps.copyPermissions(from: url, to: temporary)
        if !options.removeExtendedAttributes { FileOps.copyAttributes(from: url, to: temporary) }

        let output: URL
        switch destination {
        case .overwrite:
            try FileOps.replace(url, with: temporary)
            output = url
        case .folder(let target):
            output = FileOps.uniqueURL(in: target, name: url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: temporary, to: output)
            } catch {
                throw MetadataError.writeFailed("Could not save into \(target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if options.removeExtendedAttributes {
            // Replacing a file can carry the quarantine flag over; take it off explicitly.
            let leftover = FileSystemMetadata.attributeNames(output).filter { !FileSystemMetadata.systemManaged.contains($0) }
            _ = FileSystemMetadata.removeAttributes(leftover, from: output)
        }
        if options.preserveFileDates { try? FileOps.setDates(originalDates, on: output) }

        let after = await inspect(output, includeSpotlight: false)
        var removed = max(0, before.embeddedEntries.count - after.embeddedEntries.count)
        if options.removeExtendedAttributes {
            // macOS adds and protects some attributes itself; they don't count either way.
            let userAttributes = { (report: MetadataReport) in
                report.attributeEntries.filter { !FileSystemMetadata.systemManaged.contains($0.key) }
            }
            removed += max(0, userAttributes(before).count - userAttributes(after).count)
            let stuck = userAttributes(after)
            if !stuck.isEmpty { notes.append("Some extended attributes could not be removed: \(stuck.map(\.label).joined(separator: ", ")).") }
        }
        return CleanResult(output: output, removedCount: removed, remaining: after.embeddedEntries, notes: notes)
    }

    /// Applies viewer edits. Without `saveAs` the original file is replaced; otherwise the original stays as it was.
    @discardableResult
    public static func save(_ edits: [MetadataEdit], for url: URL, saveAs: URL? = nil) async throws -> [String] {
        let fileSections: Set<String> = [FileSystemMetadata.fileSectionID, FileSystemMetadata.attributesSectionID]
        let embedded = edits.filter { !fileSections.contains($0.sectionID) }
        let dateEdits = edits.filter { $0.sectionID == FileSystemMetadata.fileSectionID }
        let removedAttributes = edits.filter { $0.sectionID == FileSystemMetadata.attributesSectionID && $0.action == .remove }.map(\.key)
        let originalDates = FileOps.dates(of: url)
        let target = saveAs ?? url
        var notes: [String] = []

        // Validate date edits before touching anything.
        var newDates = FileOps.Dates()
        for edit in dateEdits {
            guard let text = edit.newValue, let date = Format.parseDate(text) else {
                throw MetadataError.unsupported("“\(edit.newValue ?? "")” isn't a date. Use the form 2024-05-31 14:30:00.")
            }
            if edit.key == "created" { newDates.created = date }
            if edit.key == "modified" { newDates.modified = date }
        }

        if !embedded.isEmpty {
            guard let handler = handler(for: url) else { throw MetadataError.unsupported("This kind of file can't be edited.") }
            let scratch = try FileOps.scratchFolder(near: target.deletingLastPathComponent())
            defer { try? FileManager.default.removeItem(at: scratch) }
            let temporary = scratch.appendingPathComponent(url.lastPathComponent)
            notes += try await handler.apply(embedded, to: url, writingTo: temporary)
            FileOps.copyPermissions(from: url, to: temporary)
            FileOps.copyAttributes(from: url, to: temporary, except: Set(removedAttributes))
            if let saveAs, !FileOps.sameFile(saveAs, url) {
                if FileManager.default.fileExists(atPath: saveAs.path) { try FileManager.default.removeItem(at: saveAs) }
                try FileManager.default.moveItem(at: temporary, to: saveAs)
            } else {
                try FileOps.replace(url, with: temporary)
                try? FileOps.setDates(FileOps.Dates(created: originalDates.created, modified: nil), on: url)
            }
        } else {
            if let saveAs, !FileOps.sameFile(saveAs, url) {
                if FileManager.default.fileExists(atPath: saveAs.path) { try FileManager.default.removeItem(at: saveAs) }
                try FileManager.default.copyItem(at: url, to: saveAs)
            }
            let stuck = FileSystemMetadata.removeAttributes(removedAttributes, from: target)
            if !stuck.isEmpty { notes.append("macOS kept these attributes: \(stuck.joined(separator: ", ")).") }
        }
        try FileOps.setDates(newDates, on: target)
        return notes
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
