import Foundation
import CoreServices
import UniformTypeIdentifiers

/// File-system level metadata: names, dates and permissions, extended attributes, and the Spotlight index.
enum FileSystemMetadata {
    static let fileSectionID = "file"
    static let attributesSectionID = "xattr"
    static let spotlightSectionID = "spotlight"

    static func fileSection(_ url: URL) -> MetadataSection {
        var entries: [MetadataEntry] = []
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        func add(_ key: String, _ label: String, _ value: String?, editable: Bool = false) {
            guard let value, !value.isEmpty else { return }
            entries.append(MetadataEntry(key: key, label: label, value: value, editable: editable, multiline: false, classify: false))
        }
        add("name", "Name", url.lastPathComponent)
        add("kind", "Kind", values?.localizedTypeDescription)
        if let size = values?.fileSize {
            add("size", "Size", "\(Format.bytes(size)) (\(size.formatted()) bytes)")
        }
        add("created", "Created", values?.creationDate.map(Format.date), editable: true)
        add("modified", "Modified", values?.contentModificationDate.map(Format.date), editable: true)
        add("opened", "Last opened", values?.contentAccessDate.map(Format.date))
        if let owner = attributes[.ownerAccountName] as? String {
            let group = attributes[.groupOwnerAccountName] as? String
            add("owner", "Owner", group.map { "\(owner) (\($0))" } ?? owner)
        }
        if let mode = attributes[.posixPermissions] as? Int { add("permissions", "Permissions", permissionString(mode)) }
        add("folder", "Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        return MetadataSection(id: fileSectionID, title: "File", symbol: "doc", kind: .file, entries: entries)
    }

    static func permissionString(_ mode: Int) -> String {
        let flags: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                         (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" }) + String(format: "  (%o)", mode)
    }

    // MARK: Extended attributes

    static func attributeNames(_ url: URL) -> [String] {
        let path = url.path
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer[0..<read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read >= 0 ? data.prefix(read) : nil
    }

    @discardableResult
    static func setAttribute(_ name: String, _ value: Data, on url: URL) -> Bool {
        value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) } == 0
    }

    /// Removes the named attributes; returns the names that could not be removed (the system protects some).
    static func removeAttributes(_ names: [String], from url: URL) -> [String] {
        names.filter { removexattr(url.path, $0, XATTR_NOFOLLOW) != 0 && errno != ENOATTR }
    }

    /// Attributes macOS manages itself and does not let apps remove.
    static let systemManaged: Set<String> = ["com.apple.macl", "com.apple.provenance", "com.apple.rootless"]

    static func attributesSection(_ url: URL) -> MetadataSection {
        let entries = attributeNames(url).sorted().map { name -> MetadataEntry in
            let data = attribute(name, of: url) ?? Data()
            let (label, value) = describeAttribute(name, data)
            let removable = !systemManaged.contains(name)
            return MetadataEntry(key: name, label: label, value: value, detail: name, removable: removable,
                                 highlight: highlight(forAttribute: name), classify: false)
        }
        return MetadataSection(id: attributesSectionID, title: "Extended Attributes", symbol: "tag", kind: .attributes, entries: entries,
                               note: entries.isEmpty ? nil : "Stored by macOS next to the file, not inside it. They stay with the file when it is copied on a Mac, AirDropped or zipped by Finder.")
    }

    static func highlight(forAttribute name: String) -> Highlight? {
        switch name {
        case "com.apple.metadata:kMDItemWhereFroms", "com.apple.quarantine", "com.apple.metadata:kMDItemDownloadedDate":
            return .history
        case "com.apple.lastuseddate#PS":
            return .history
        case "com.apple.metadata:kMDItemCreator":
            return .device
        default:
            return nil
        }
    }

    static func describeAttribute(_ name: String, _ data: Data) -> (String, String) {
        let labels: [String: String] = [
            "com.apple.metadata:kMDItemWhereFroms": "Downloaded from",
            "com.apple.metadata:kMDItemDownloadedDate": "Downloaded",
            "com.apple.metadata:_kMDItemUserTags": "Finder tags",
            "com.apple.metadata:kMDItemFinderComment": "Finder comment",
            "com.apple.metadata:kMDItemCreator": "Created by",
            "com.apple.quarantine": "Quarantine",
            "com.apple.lastuseddate#PS": "Last opened",
            "com.apple.FinderInfo": "Finder info",
            "com.apple.ResourceFork": "Resource fork",
            "com.apple.TextEncoding": "Text encoding",
            "com.apple.provenance": "Provenance (system)",
            "com.apple.macl": "Access list (system)",
        ]
        let label = labels[name] ?? name.replacingOccurrences(of: "com.apple.metadata:", with: "")
        switch name {
        case "com.apple.quarantine":
            let parts = String(decoding: data, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            var pieces: [String] = []
            if parts.count > 2, !parts[2].isEmpty { pieces.append("by \(parts[2])") }
            if parts.count > 1, let seconds = Int(parts[1], radix: 16), seconds > 0 {
                pieces.append("on \(Format.date(Date(timeIntervalSince1970: TimeInterval(seconds))))")
            }
            return (label, pieces.isEmpty ? String(decoding: data, as: UTF8.self) : "Downloaded " + pieces.joined(separator: " "))
        case "com.apple.lastuseddate#PS" where data.count >= 8:
            let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
            return (label, Format.date(Date(timeIntervalSince1970: TimeInterval(seconds))))
        case "com.apple.metadata:_kMDItemUserTags":
            let tags = (plistValue(data) as? [String] ?? []).map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
            return (label, tags.joined(separator: ", "))
        default:
            break
        }
        if let value = plistValue(data) { return (label, describe(value)) }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) {
            return (label, text)
        }
        return (label, "\(Format.bytes(data.count)) of binary data")
    }

    static func plistValue(_ data: Data) -> Any? {
        guard data.starts(with: "bplist") || data.starts(with: "<?xml") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let date as Date: return Format.date(date)
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map(describe).joined(separator: "\n")
        case let data as Data: return "\(Format.bytes(data.count)) of binary data"
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { "\($0): \(describe(dictionary[$0]!))" }.joined(separator: "\n")
        default: return "\(value)"
        }
    }

    // MARK: Spotlight

    static func spotlightSection(_ url: URL) -> MetadataSection? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let names = MDItemCopyAttributeNames(item) as? [String] else { return nil }
        let skipped: Set<String> = ["kMDItemContentTypeTree", "kMDItemPhysicalSize", "kMDItemLogicalSize", "kMDItemDocumentIdentifier",
                                    "kMDItemInterestingDate_Ranking", "kMDItemContentCreationDate_Ranking", "kMDItemDateAdded_Ranking",
                                    "kMDItemDisplayName", "kMDItemContentType", "kMDItemKind"]
        let entries = names.sorted().compactMap { name -> MetadataEntry? in
            guard !name.hasPrefix("kMDItemFS"), !name.hasPrefix("_"), !skipped.contains(name),
                  let value = MDItemCopyAttribute(item, name as CFString) else { return nil }
            let text = describe(value).replacingOccurrences(of: "\n", with: ", ")
            guard !text.isEmpty else { return nil }
            let label = Format.words(name.replacingOccurrences(of: "kMDItem", with: ""))
            return MetadataEntry(key: name, label: label, value: text, detail: name, multiline: false)
        }
        guard !entries.isEmpty else { return nil }
        return MetadataSection(id: spotlightSectionID, title: "Spotlight Index", symbol: "magnifyingglass", kind: .spotlight, entries: entries,
                               note: "What Spotlight extracted when it indexed this file. It refreshes on its own after the file changes.")
    }
}

/// Writing helpers: temporary files on the same volume, atomic replacement, and carrying attributes over.
enum FileOps {
    /// A scratch folder on the same volume as `url`, for building the replacement file.
    static func scratchFolder(near url: URL) throws -> URL {
        do {
            return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        } catch {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MetaScrub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }

    /// Puts `newFile` in place of `original`, taking only the new file's own metadata.
    static func replace(_ original: URL, with newFile: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(original, withItemAt: newFile, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            throw MetadataError.writeFailed("Could not replace \(original.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// `folder/name`, or `folder/name 2.ext`, `name 3.ext`… when that exists.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    static func copyAttributes(from source: URL, to destination: URL, except excluded: Set<String> = []) {
        for name in FileSystemMetadata.attributeNames(source) where !excluded.contains(name) && !FileSystemMetadata.systemManaged.contains(name) {
            if let value = FileSystemMetadata.attribute(name, of: source) {
                FileSystemMetadata.setAttribute(name, value, on: destination)
            }
        }
    }

    static func copyPermissions(from source: URL, to destination: URL) {
        if let mode = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
    }

    struct Dates {
        var created: Date?
        var modified: Date?
    }

    static func dates(of url: URL) -> Dates {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return Dates(created: values?.creationDate, modified: values?.contentModificationDate)
    }

    static func setDates(_ dates: Dates, on url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created = dates.created { attributes[.creationDate] = created }
        if let modified = dates.modified { attributes[.modificationDate] = modified }
        guard !attributes.isEmpty else { return }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    static func sameFile(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path == second.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension URL {
    var typeIdentifier: UTType? {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: pathExtension)
    }
}
