import Foundation

/// WAV (RIFF, little-endian) and AIFF (IFF, big-endian): a list of tagged chunks. Cleaning keeps the
/// chunks needed for playback and loop/marker data; edits rewrite the text chunks.
struct ChunkAudioHandler: FormatHandler {
    enum Kind { case wav, aiff }
    let kind: Kind

    struct Chunk {
        var id: String
        var start: Int
        var payload: Int
        var size: Int
        /// Header, payload and pad byte as they sit in the file.
        var stored: Range<Int>
    }

    struct Layout {
        var form: String
        var chunks: [Chunk]
    }

    private var littleEndian: Bool { kind == .wav }

    func layout(_ data: Data) throws -> Layout {
        let magic = kind == .wav ? "RIFF" : "FORM"
        guard data.count >= 12, data.starts(with: magic) else { throw MetadataError.corrupt("The file header is damaged.") }
        let form = data.fourCC(8)
        var chunks: [Chunk] = []
        var offset = 12
        while offset + 8 <= data.count {
            let id = data.fourCC(offset)
            var size = littleEndian ? data.u32le(offset + 4) : data.u32be(offset + 4)
            let payload = offset + 8
            if payload + size > data.count {
                // Unfinished recordings sometimes claim more audio than the file holds.
                guard id == "data" || id == "SSND" else { throw MetadataError.corrupt("The “\(id)” chunk runs past the end of the file.") }
                size = data.count - payload
            }
            let end = min(data.count, payload + size + (size & 1))
            chunks.append(Chunk(id: id, start: offset, payload: payload, size: size, stored: offset..<end))
            offset = end
        }
        return Layout(form: form, chunks: chunks)
    }

    private func u32(_ data: Data, _ offset: Int) -> Int { littleEndian ? data.u32le(offset) : data.u32be(offset) }

    // MARK: Chunk meaning

    static let wavKept: Set<String> = ["fmt ", "data", "fact", "cue ", "smpl", "inst", "plst", "acid"]
    static let aiffKept: Set<String> = ["COMM", "SSND", "FVER", "MARK", "INST", "CHAN", "AESD"]
    static let padding: Set<String> = ["JUNK", "junk", "PAD ", "FLLR", "free"]

    static let infoNames: [String: String] = [
        "INAM": "Title", "IART": "Artist", "IPRD": "Album", "ICMT": "Comment", "ICRD": "Date", "IGNR": "Genre", "ICOP": "Copyright",
        "ISFT": "Software", "IENG": "Engineer", "ITCH": "Technician", "IKEY": "Keywords", "ISBJ": "Subject", "ISRC": "Source",
        "ITRK": "Track", "IPRT": "Track", "IARL": "Archival location", "ICMS": "Commissioned by", "ILNG": "Language",
        "IMED": "Medium", "ISRF": "Source form", "ICRP": "Cropped", "IDIM": "Dimensions", "IDPI": "Dots per inch",
        "ILGT": "Lightness", "IPLT": "Palette", "ISHP": "Sharpness", "ISMP": "SMPTE time code", "IDIT": "Digitized",
        "IENC": "Encoded by", "IWRI": "Writer", "IMUS": "Composer", "IPRO": "Producer", "IRTD": "Rating", "ISTR": "Performer",
    ]

    static let aiffNames: [String: String] = ["NAME": "Name", "AUTH": "Author", "(c) ": "Copyright", "ANNO": "Annotation"]

    func read(_ url: URL) async throws -> FormatReport {
        let data = try mappedData(url)
        let layout = try layout(data)
        var report = FormatReport(format: kind == .wav ? "WAV audio" : (layout.form == "AIFC" ? "AIFF-C audio" : "AIFF audio"),
                                  canEdit: true, canClean: true)
        report.facts = await AudioFacts.read(url)
        if kind == .wav {
            report.sections = wavSections(data, layout)
        } else {
            report.sections = aiffSections(data, layout)
        }
        return report
    }

    private func wavSections(_ data: Data, _ layout: Layout) -> [MetadataSection] {
        var info: [MetadataEntry] = []
        var sections: [MetadataSection] = []
        var other: [MetadataEntry] = []
        for (index, chunk) in layout.chunks.enumerated() {
            switch chunk.id {
            case "LIST" where chunk.size >= 4 && data.fourCC(chunk.payload) == "INFO":
                info += infoFields(data, chunk).map { field in
                    MetadataEntry(key: field.id, label: Self.infoNames[field.id] ?? field.id, value: field.value, detail: field.id,
                                  editable: true, removable: true)
                }
            case "bext":
                sections.append(MetadataSection(id: "bext", title: "Broadcast (bext)", symbol: "antenna.radiowaves.left.and.right",
                                                entries: bextEntries(data, chunk), note: "Read-only. Clean removes it."))
            case "id3 ", "ID3 ":
                if let tag = try? ID3.parse(data.bytes(chunk.payload, chunk.size)) {
                    sections.append(MetadataSection(id: "id3", title: "ID3 Tag", symbol: "music.note.list",
                                                    entries: ID3.entries(tag, sectionEditable: false), note: "Read-only. Clean removes it."))
                }
            case "iXML", "_PMX", "aXML":
                let title = chunk.id == "_PMX" ? "XMP" : chunk.id
                sections.append(MetadataSection(id: "chunk\(index)", title: title, symbol: "curlybraces", entries: [
                    MetadataEntry(key: "chunk\(index)", label: "\(title) document", value: data.text(chunk.payload, chunk.size), removable: true, multiline: true),
                ]))
            default:
                if !Self.wavKept.contains(chunk.id) && !Self.padding.contains(chunk.id) && !(chunk.id == "LIST" && isAdtl(data, chunk)) {
                    other.append(MetadataEntry(key: "chunk\(index)", label: "“\(chunk.id)” chunk", value: Format.bytes(chunk.size), removable: true))
                }
            }
        }
        let templates = ["INAM", "IART", "IPRD", "ICMT", "ICRD", "IGNR", "ICOP", "ISFT", "IENG", "IKEY", "ITRK"]
            .map { FieldTemplate($0, Self.infoNames[$0] ?? $0) }
        sections.insert(MetadataSection(id: "info", title: "INFO List", symbol: "music.note.list", entries: info, templates: templates,
                                        customFieldHint: "Four-letter INFO id, e.g. ISRC"), at: 0)
        if !other.isEmpty {
            sections.append(MetadataSection(id: "chunks", title: "Other Chunks", symbol: "square.stack.3d.up", entries: other,
                                            note: "Chunks that playback doesn't need. Clean removes them."))
        }
        return sections
    }

    private func isAdtl(_ data: Data, _ chunk: Chunk) -> Bool {
        chunk.size >= 4 && data.fourCC(chunk.payload) == "adtl"
    }

    private func infoFields(_ data: Data, _ chunk: Chunk) -> [(id: String, value: String)] {
        var fields: [(String, String)] = []
        var offset = chunk.payload + 4
        let end = chunk.payload + chunk.size
        while offset + 8 <= end {
            let id = data.fourCC(offset)
            let size = data.u32le(offset + 4)
            guard offset + 8 + size <= end else { break }
            fields.append((id, data.text(offset + 8, size)))
            offset += 8 + size + (size & 1)
        }
        return fields
    }

    private func bextEntries(_ data: Data, _ chunk: Chunk) -> [MetadataEntry] {
        guard chunk.size >= 346 else { return [] }
        let base = chunk.payload
        var entries: [MetadataEntry] = []
        func add(_ key: String, _ label: String, _ value: String) {
            if !value.isEmpty { entries.append(MetadataEntry(key: "bext:\(key)", label: label, value: value)) }
        }
        add("description", "Description", data.text(base, 256))
        add("originator", "Originator", data.text(base + 256, 32))
        add("reference", "Originator reference", data.text(base + 288, 32))
        add("date", "Origination date", data.text(base + 320, 10))
        add("time", "Origination time", data.text(base + 330, 8))
        let reference = data.u32le(base + 338) | data.u32le(base + 342) << 32
        if reference > 0 { add("timeref", "Time reference (samples)", "\(reference)") }
        if chunk.size > 602 { add("history", "Coding history", data.text(base + 602, chunk.size - 602)) }
        return entries
    }

    private func aiffSections(_ data: Data, _ layout: Layout) -> [MetadataSection] {
        var text: [MetadataEntry] = []
        var sections: [MetadataSection] = []
        var other: [MetadataEntry] = []
        var seen: [String: Int] = [:]
        for (index, chunk) in layout.chunks.enumerated() {
            switch chunk.id {
            case "NAME", "AUTH", "(c) ", "ANNO":
                let occurrence = seen[chunk.id, default: 0]
                seen[chunk.id] = occurrence + 1
                let key = occurrence > 0 ? "\(chunk.id)#\(occurrence)" : chunk.id
                text.append(MetadataEntry(key: key, label: Self.aiffNames[chunk.id] ?? chunk.id, value: data.text(chunk.payload, chunk.size),
                                          detail: chunk.id, editable: true, removable: true))
            case "ID3 ", "id3 ":
                if let tag = try? ID3.parse(data.bytes(chunk.payload, chunk.size)) {
                    sections.append(MetadataSection(id: "id3", title: "ID3 Tag", symbol: "music.note.list",
                                                    entries: ID3.entries(tag, sectionEditable: false), note: "Read-only. Clean removes it."))
                }
            case "COMT":
                var entries: [MetadataEntry] = []
                let count = chunk.size >= 2 ? data.u16be(chunk.payload) : 0
                var offset = chunk.payload + 2
                for number in 0..<count where offset + 8 <= chunk.payload + chunk.size {
                    let length = data.u16be(offset + 6)
                    guard data.has(offset + 8, length) else { break }
                    entries.append(MetadataEntry(key: "comt\(number)", label: "Comment \(number + 1)", value: data.text(offset + 8, length)))
                    offset += 8 + length + (length & 1)
                }
                sections.append(MetadataSection(id: "comments", title: "Comments", symbol: "text.bubble", entries: entries,
                                                note: "Read-only. Clean removes them."))
            default:
                if !Self.aiffKept.contains(chunk.id) && !Self.padding.contains(chunk.id) {
                    other.append(MetadataEntry(key: "chunk\(index)", label: "“\(chunk.id)” chunk", value: Format.bytes(chunk.size), removable: true))
                }
            }
        }
        sections.insert(MetadataSection(id: "text", title: "Text Chunks", symbol: "music.note.list", entries: text,
                                        templates: ["NAME", "AUTH", "(c) ", "ANNO"].map { FieldTemplate($0, Self.aiffNames[$0]!) }), at: 0)
        if !other.isEmpty {
            sections.append(MetadataSection(id: "chunks", title: "Other Chunks", symbol: "square.stack.3d.up", entries: other,
                                            note: "Chunks that playback doesn't need. Clean removes them."))
        }
        return sections
    }

    // MARK: Writing

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try layout(data)
        let kept = layout.chunks.filter { chunk in
            kind == .wav ? Self.wavKept.contains(chunk.id) || (chunk.id == "LIST" && isAdtl(data, chunk)) : Self.aiffKept.contains(chunk.id)
        }
        try write(layout.form, kept.map { .stored($0) }, data: data, to: destination)
        return []
    }

    enum Piece {
        case stored(Chunk)
        case new(String, Data)
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try layout(data)
        let removedChunks = Set(edits.filter { $0.action == .remove && $0.key.hasPrefix("chunk") }.compactMap { Int($0.key.dropFirst(5)) })
        let textEdits = edits.filter { $0.sectionID == (kind == .wav ? "info" : "text") }
        guard edits.allSatisfy({ $0.sectionID == "info" || $0.sectionID == "text" || $0.key.hasPrefix("chunk") }) else {
            throw MetadataError.unsupported("This section is read-only.")
        }
        var pieces: [Piece] = []
        if kind == .wav {
            // Collect the INFO fields, apply edits, and write them back as one LIST chunk before the audio.
            var fields = layout.chunks.filter { $0.id == "LIST" && $0.size >= 4 && data.fourCC($0.payload) == "INFO" }
                .flatMap { infoFields(data, $0) }
            for edit in textEdits {
                if let index = fields.firstIndex(where: { $0.id == edit.key }) {
                    if let value = edit.newValue { fields[index].value = value } else { fields.remove(at: index) }
                } else if let value = edit.newValue {
                    let id = edit.key.uppercased()
                    guard id.count == 4, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                        throw MetadataError.unsupported("INFO ids are four letters, e.g. ISRC.")
                    }
                    fields.append((id, value))
                }
            }
            var list = ByteWriter()
            list.ascii("INFO")
            for field in fields where !field.value.isEmpty {
                let text = Data(field.value.utf8) + Data([0])
                list.ascii(field.id)
                list.u32le(text.count)
                list.append(text)
                if text.count & 1 == 1 { list.u8(0) }
            }
            var placed = false
            for (index, chunk) in layout.chunks.enumerated() where !removedChunks.contains(index) {
                if chunk.id == "LIST" && chunk.size >= 4 && data.fourCC(chunk.payload) == "INFO" { continue }
                if chunk.id == "data" && !placed {
                    if !fields.isEmpty { pieces.append(.new("LIST", list.data)) }
                    placed = true
                }
                pieces.append(.stored(chunk))
            }
            if !placed && !fields.isEmpty { pieces.append(.new("LIST", list.data)) }
        } else {
            let current = aiffSections(data, layout).first { $0.id == "text" }?.entries ?? []
            var textIndex = 0
            var values: [String: String?] = [:]
            for edit in textEdits { values[edit.key] = edit.newValue }
            var placed = false
            for (index, chunk) in layout.chunks.enumerated() where !removedChunks.contains(index) {
                if Self.aiffNames[chunk.id] != nil {
                    let key = current[textIndex].key
                    textIndex += 1
                    if let change = values.removeValue(forKey: key) {
                        if let value = change, !value.isEmpty { pieces.append(.new(chunk.id, Data(value.utf8))) }
                        continue
                    }
                }
                if chunk.id == "SSND" && !placed {
                    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                        guard let value, !value.isEmpty, Self.aiffNames[key] != nil else { continue }
                        pieces.append(.new(key, Data(value.utf8)))
                    }
                    values.removeAll()
                    placed = true
                }
                pieces.append(.stored(chunk))
            }
        }
        try write(layout.form, pieces, data: data, to: destination)
        return []
    }

    private func write(_ form: String, _ pieces: [Piece], data: Data, to destination: URL) throws {
        func header(_ id: String, _ size: Int) -> Data {
            var writer = ByteWriter()
            writer.ascii(id)
            if littleEndian { writer.u32le(size) } else { writer.u32be(size) }
            return writer.data
        }
        var total = 4
        for piece in pieces {
            switch piece {
            case .stored(let chunk): total += 8 + chunk.size + (chunk.size & 1)
            case .new(_, let payload): total += 8 + payload.count + (payload.count & 1)
            }
        }
        guard total < 1 << 32 else { throw MetadataError.unsupported("Files over 4 GB aren't supported.") }
        let stream = try StreamWriter(url: destination)
        try stream.write(header(kind == .wav ? "RIFF" : "FORM", total) + Data(form.utf8))
        for piece in pieces {
            switch piece {
            case .stored(let chunk):
                try stream.write(header(chunk.id, chunk.size))
                try stream.write(data.bytes(chunk.payload, chunk.size))
                if chunk.size & 1 == 1 { try stream.write(Data([0])) }
            case .new(let id, let payload):
                try stream.write(header(id, payload.count) + payload + (payload.count & 1 == 1 ? Data([0]) : Data()))
            }
        }
        try stream.close()
    }
}
