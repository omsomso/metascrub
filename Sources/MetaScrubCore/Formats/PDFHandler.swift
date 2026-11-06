import Foundation
import PDFKit

/// PDFs through PDFKit. PDFKit re-saves the whole document (dropping old revisions), always stamps its own
/// Producer and keeps the XMP packet, so the output is patched afterwards with same-length edits.
struct PDFHandler: FormatHandler {
    static let standardKeys: [(String, String)] = [
        ("Title", "Title"), ("Author", "Author"), ("Subject", "Subject"), ("Keywords", "Keywords"), ("Creator", "Creator"),
        ("Producer", "Producer"), ("CreationDate", "Created"), ("ModDate", "Modified"),
    ]

    func read(_ url: URL) async throws -> FormatReport {
        guard let document = PDFDocument(url: url) else { throw MetadataError.unreadable("PDFKit can't open this PDF.") }
        var report = FormatReport(format: "PDF document")
        report.facts.append(Fact("Pages", "\(document.pageCount)", symbol: "doc.on.doc"))
        if let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let millimetres = { (points: CGFloat) in Int((points / 72 * 25.4).rounded()) }
            report.facts.append(Fact("Page size", "\(millimetres(bounds.width)) × \(millimetres(bounds.height)) mm", symbol: "ruler"))
        }
        report.facts.append(Fact("Version", "PDF \(document.majorVersion).\(document.minorVersion)", symbol: "number"))
        if document.isEncrypted { report.facts.append(Fact("Security", document.isLocked ? "Password protected" : "Encrypted", symbol: "lock")) }
        let writable = !document.isLocked
        report.canEdit = writable
        report.canClean = writable
        if !writable { report.notes.append("This PDF is password protected, so it can't be changed.") }

        var info: [MetadataEntry] = []
        let standard = Set(Self.standardKeys.map(\.0))
        let rawInfo = document.documentRef.map(Self.infoDictionary) ?? [:]
        for (key, label) in Self.standardKeys {
            guard let value = rawInfo[key], !value.isEmpty else { continue }
            let highlight: Highlight? = key == "Author" ? .people : (key == "Creator" || key == "Producer") ? .device : nil
            info.append(MetadataEntry(key: key, label: label, value: value, detail: key, editable: writable, removable: writable,
                                      multiline: key == "Subject" && value.count > 60, highlight: highlight, classify: false))
        }
        for key in rawInfo.keys.sorted() where !standard.contains(key) {
            info.append(MetadataEntry(key: key, label: Format.words(key), value: rawInfo[key] ?? "", detail: "custom", removable: writable))
        }
        report.sections.append(MetadataSection(id: "pdf.info", title: "Document Info", symbol: "doc.text", entries: info,
                                               templates: writable ? Self.standardKeys.filter { rawInfo[$0.0] == nil }.map { FieldTemplate($0.0, $0.1) } : []))

        if let xmp = document.documentRef.flatMap(Self.xmpPacket) {
            var entries = [MetadataEntry(key: "xmp", label: "XMP packet", value: "\(Format.bytes(xmp.count)) of XML", removable: writable,
                                         multiline: false, highlight: .history)]
            entries += Self.xmpFields(xmp)
            report.sections.append(MetadataSection(id: "pdf.xmp", title: "XMP Metadata", symbol: "curlybraces", entries: entries,
                                                   note: "A second copy of the document details that many apps prefer over Document Info. Remove the packet to drop all of it."))
        }

        var annotationAuthors = Set<String>()
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let name = annotation.userName, !name.isEmpty { annotationAuthors.insert(name) }
            }
        }
        if !annotationAuthors.isEmpty {
            report.sections.append(MetadataSection(id: "pdf.annotations", title: "Comments & Markup", symbol: "text.bubble", entries: [
                MetadataEntry(key: "authors", label: "Comment authors", value: annotationAuthors.sorted().joined(separator: ", "), highlight: .people),
            ], note: "Names attached to comments and markup. Clean removes the names but keeps the comments."))
        }
        return report
    }

    static func infoDictionary(_ document: CGPDFDocument) -> [String: String] {
        guard let info = document.info else { return [:] }
        final class Box: @unchecked Sendable { var values: [String: String] = [:] }
        let box = Box()
        CGPDFDictionaryApplyBlock(info, { key, object, _ in
            let name = String(cString: key)
            var string: CGPDFStringRef?
            var nameValue: UnsafePointer<CChar>?
            var integer: CGPDFInteger = 0
            var real: CGPDFReal = 0
            if CGPDFObjectGetValue(object, .string, &string), let string {
                if let date = CGPDFStringCopyDate(string) as Date?, name.hasSuffix("Date") {
                    box.values[name] = Format.date(date)
                } else if let text = CGPDFStringCopyTextString(string) as String? {
                    box.values[name] = text.trimmingCharacters(in: .whitespaces)  // patched strings are space-padded
                }
            } else if CGPDFObjectGetValue(object, .name, &nameValue), let nameValue {
                box.values[name] = String(cString: nameValue)
            } else if CGPDFObjectGetValue(object, .integer, &integer) {
                box.values[name] = "\(integer)"
            } else if CGPDFObjectGetValue(object, .real, &real) {
                box.values[name] = "\(real)"
            }
            return true
        }, nil)
        return box.values
    }

    static func xmpPacket(_ document: CGPDFDocument) -> Data? {
        guard let catalog = document.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(stream, &format) as Data?
    }

    /// Simple XMP properties, element or attribute form, as read-only entries.
    static func xmpFields(_ data: Data) -> [MetadataEntry] {
        guard let document = try? XMLDocument(data: data) else { return [] }
        var entries: [MetadataEntry] = []
        let descriptions = (try? document.nodes(forXPath: "//*[local-name()='Description']")) ?? []
        for case let description as XMLElement in descriptions {
            for attribute in description.attributes ?? [] {
                guard let name = attribute.name, name.contains(":"), !name.hasPrefix("xmlns"), !name.hasPrefix("rdf:") else { continue }
                entries.append(MetadataEntry(key: "xmp:\(name)", label: label(name), value: attribute.stringValue ?? "", detail: name))
            }
            for child in description.children ?? [] {
                guard let element = child as? XMLElement, let name = element.name else { continue }
                let values = ((try? element.nodes(forXPath: ".//*[local-name()='li']")) ?? []).compactMap(\.stringValue)
                let value = values.isEmpty ? (element.stringValue ?? "") : values.joined(separator: "; ")
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append(MetadataEntry(key: "xmp:\(name)", label: label(name), value: trimmed, detail: name))
            }
        }
        return entries
    }

    private static func label(_ qualified: String) -> String {
        Format.words(String(qualified.split(separator: ":").last ?? Substring(qualified)))
    }

    // MARK: Writing

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        guard let document = PDFDocument(url: source), !document.isLocked else {
            throw MetadataError.unsupported("This PDF is password protected.")
        }
        document.documentAttributes = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                annotation.userName = nil
                annotation.modificationDate = nil
            }
        }
        guard document.write(to: destination) else { throw MetadataError.writeFailed("PDFKit couldn't save the PDF.") }
        var data = try Data(contentsOf: destination)
        // Quartz stamps its own version and the save time; blank those entries out too.
        for key in ["Producer", "CreationDate", "ModDate"] { PDFPatcher.blankInfoEntry(&data, key: key) }
        PDFPatcher.removeMetadataStreams(&data)
        try data.write(to: destination)
        return []
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        guard let document = PDFDocument(url: source), !document.isLocked else {
            throw MetadataError.unsupported("This PDF is password protected.")
        }
        let rawInfo = document.documentRef.map(Self.infoDictionary) ?? [:]
        var attributes = document.documentAttributes ?? [:]
        var removeXMP = false
        var producer = rawInfo["Producer"]
        for edit in edits {
            switch (edit.sectionID, edit.key) {
            case ("pdf.xmp", "xmp"):
                removeXMP = edit.action == .remove
            case ("pdf.info", "Producer"):
                producer = edit.newValue
            case ("pdf.info", let key):
                let attribute = PDFDocumentAttribute(rawValue: key)
                guard let value = edit.newValue else {
                    attributes.removeValue(forKey: attribute)
                    continue
                }
                if key.hasSuffix("Date") {
                    guard let date = Format.parseDate(value) else {
                        throw MetadataError.unsupported("“\(value)” isn't a date. Use the form 2024-05-31 14:30:00.")
                    }
                    attributes[attribute] = date
                } else if key == "Keywords" {
                    attributes[attribute] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    attributes[attribute] = value
                }
            default:
                throw MetadataError.unsupported("This section is read-only.")
            }
        }
        attributes.removeValue(forKey: PDFDocumentAttribute.producerAttribute)
        document.documentAttributes = attributes
        guard document.write(to: destination) else { throw MetadataError.writeFailed("PDFKit couldn't save the PDF.") }
        var data = try Data(contentsOf: destination)
        var notes: [String] = []
        if !PDFPatcher.setProducer(&data, to: producer ?? "") {
            notes.append("macOS records itself as the Producer when it saves a PDF; the Producer you set was too long to put back.")
        }
        if removeXMP { PDFPatcher.removeMetadataStreams(&data) }
        try data.write(to: destination)
        let customKeys = rawInfo.keys.filter { key in !Self.standardKeys.contains { $0.0 == key } }
        if !customKeys.isEmpty { notes.append("PDFKit doesn't keep custom fields when saving: \(customKeys.sorted().joined(separator: ", ")).") }
        if !removeXMP && Self.xmpPacket(CGPDFDocument(source as CFURL)!) != nil && edits.contains(where: { $0.sectionID == "pdf.info" }) {
            notes.append("This PDF also has XMP metadata, which some apps show instead of Document Info.")
        }
        return notes
    }
}

/// Byte-level fixes to PDFs written by Quartz. Every edit keeps the length the same, so the
/// cross-reference table stays valid.
enum PDFPatcher {
    private static func find(_ needle: String, in data: Data, from start: Int = 0, backwards: Bool = false) -> Int? {
        let bytes = Data(needle.utf8)
        let range = backwards ? data.range(of: bytes, options: .backwards, in: data.startIndex..<data.endIndex)
            : data.range(of: bytes, in: (data.startIndex + start)..<data.endIndex)
        return range.map { $0.lowerBound - data.startIndex }
    }

    /// Offsets of the `(` and `)` around the last `/Key (…)` literal string, if any.
    private static func literal(_ key: String, in data: Data) -> (key: Int, open: Int, close: Int)? {
        guard let start = find("/\(key) (", in: data, backwards: true) else { return nil }
        let open = start + key.count + 2
        var index = open + 1
        var depth = 1
        while index < data.count && depth > 0 {
            switch data.byte(index) {
            case UInt8(ascii: "\\"): index += 1
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"): depth -= 1
            default: break
            }
            index += 1
        }
        guard depth == 0 else { return nil }
        return (start, open, index - 1)
    }

    /// Turns a whole `/Key (value)` Info entry into spaces, as if it had never been written.
    static func blankInfoEntry(_ data: inout Data, key: String) {
        guard let found = literal(key, in: data) else { return }
        blank(&data, found.key, found.close + 1 - found.key)
    }

    /// Replaces the Info dictionary's Producer string with `text` (spaces when empty), padded to the old length.
    @discardableResult
    static func setProducer(_ data: inout Data, to text: String) -> Bool {
        guard let found = literal("Producer", in: data) else { return true }
        let (open, close) = (found.open, found.close)
        let available = close - open - 1
        var escaped = Data()
        for scalar in text.unicodeScalars {
            guard scalar.isASCII else { return false }
            if scalar == "(" || scalar == ")" || scalar == "\\" { escaped.append(UInt8(ascii: "\\")) }
            escaped.append(UInt8(scalar.value))
        }
        guard escaped.count <= available else { return false }
        escaped.append(Data(repeating: UInt8(ascii: " "), count: available - escaped.count))
        data.replaceSubrange((data.startIndex + open + 1)..<(data.startIndex + close), with: escaped)
        return true
    }

    /// Unlinks every `/Metadata N 0 R` stream and blanks its contents. Returns how many were removed.
    @discardableResult
    static func removeMetadataStreams(_ data: inout Data) -> Int {
        // Latin-1 maps each byte to one character, so string offsets are byte offsets.
        guard let text = String(data: data, encoding: .isoLatin1),
              let pattern = try? NSRegularExpression(pattern: "/Metadata\\s+(\\d+)\\s+0\\s+R") else { return 0 }
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        var removed = 0
        for match in matches.reversed() {
            let number = (text as NSString).substring(with: match.range(at: 1))
            blank(&data, match.range.location, match.range.length)
            guard let objectRange = text.range(of: "(^|[\\r\\n ])\(number)\\s+0\\s+obj", options: .regularExpression) else { continue }
            let objectStart = text.utf16.distance(from: text.startIndex, to: objectRange.upperBound)
            guard let streamKeyword = find("stream", in: data, from: objectStart),
                  let endKeyword = find("endstream", in: data, from: streamKeyword + 6) else { continue }
            var start = streamKeyword + 6
            if start < data.count, data.byte(start) == 0x0D { start += 1 }
            if start < data.count, data.byte(start) == 0x0A { start += 1 }
            var end = endKeyword
            while end > start, [0x0A, 0x0D].contains(data.byte(end - 1)) { end -= 1 }
            if end > start { blank(&data, start, end - start) }
            // Without the filter the blanked stream is plain (empty) text.
            let dictionary = String(data: data.bytes(objectStart, streamKeyword - objectStart), encoding: .isoLatin1) ?? ""
            if let filter = dictionary.range(of: "/Filter /FlateDecode") {
                blank(&data, objectStart + dictionary.distance(from: dictionary.startIndex, to: filter.lowerBound), "/Filter /FlateDecode".count)
            }
            removed += 1
        }
        return removed
    }

    private static func blank(_ data: inout Data, _ offset: Int, _ length: Int) {
        data.replaceSubrange((data.startIndex + offset)..<(data.startIndex + offset + length),
                             with: Data(repeating: UInt8(ascii: " "), count: length))
    }
}
