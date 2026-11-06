import Foundation
import AVFoundation

/// Duration and stream format for any audio file Core Audio can open.
enum AudioFacts {
    static func read(_ url: URL) async -> [Fact] {
        let asset = AVURLAsset(url: url)
        var facts: [Fact] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            facts.append(Fact("Duration", Format.duration(duration.seconds), symbol: "clock"))
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            var parts: [String] = []
            if let description = try? await track.load(.formatDescriptions).first,
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                parts.append(Format.hertz(stream.mSampleRate))
                parts.append(Format.channels(Int(stream.mChannelsPerFrame)))
                if stream.mBitsPerChannel > 0 { parts.append("\(stream.mBitsPerChannel)-bit") }
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                parts.append("\(Int((rate / 1000).rounded())) kbps")
            }
            if !parts.isEmpty { facts.append(Fact("Audio", parts.joined(separator: " · "), symbol: "waveform")) }
        }
        return facts
    }
}

// MARK: - MP3

struct MP3Handler: FormatHandler {
    struct Layout {
        var tags: [ID3.Tag]
        var audio: Range<Int>
        var ape: (range: Range<Int>, items: [(String, String)])?
        var v1: ID3.V1?
    }

    static func layout(_ data: Data) throws -> Layout {
        var tags: [ID3.Tag] = []
        var start = 0
        while let tag = try ID3.parse(data, at: start) {
            tags.append(tag)
            start += tag.size
        }
        var end = data.count
        let v1 = ID3.parseV1(data)
        if v1 != nil {
            end -= 128
            if end >= 227, data.starts(with: "TAG+", at: end - 227) { end -= 227 }
        }
        var ape: (range: Range<Int>, items: [(String, String)])?
        if let found = ID3.parseAPE(data, end: end), found.start >= start {
            ape = (found.start..<end, found.items)
            end = found.start
        }
        guard start <= end else { throw MetadataError.corrupt("The MP3 tags overlap the audio.") }
        return Layout(tags: tags, audio: start..<end, ape: ape, v1: v1)
    }

    static func templates(version: Int) -> [FieldTemplate] {
        [FieldTemplate("TIT2", "Title"), FieldTemplate("TPE1", "Artist"), FieldTemplate("TALB", "Album"),
         FieldTemplate("TPE2", "Album artist"), FieldTemplate(version == 4 ? "TDRC" : "TYER", "Year"), FieldTemplate("TRCK", "Track"),
         FieldTemplate("TPOS", "Disc"), FieldTemplate("TCON", "Genre"), FieldTemplate("TCOM", "Composer"), FieldTemplate("COMM", "Comment"),
         FieldTemplate("TCOP", "Copyright"), FieldTemplate("TPUB", "Publisher"), FieldTemplate("TBPM", "BPM"),
         FieldTemplate("USLT", "Lyrics"), FieldTemplate("TENC", "Encoded by")]
    }

    func read(_ url: URL) async throws -> FormatReport {
        let data = try mappedData(url)
        let layout = try Self.layout(data)
        var report = FormatReport(format: "MP3 audio", canEdit: true, canClean: true)
        report.facts = await AudioFacts.read(url)
        let primary = layout.tags.first
        let version = primary?.version ?? 3
        let editable = version >= 3
        report.sections.append(MetadataSection(
            id: "id3v2", title: primary.map { "ID3v2.\($0.version) Tag" } ?? "ID3v2 Tag", symbol: "music.note.list",
            entries: primary.map { ID3.entries($0, sectionEditable: editable) } ?? [],
            templates: editable ? Self.templates(version: version) : [],
            customFieldHint: editable ? "Custom field name (saved as TXXX), or a 4-letter frame ID" : nil,
            note: editable ? nil : "ID3v2.2 tags are read-only here. Clean removes the tag."))
        for (index, extra) in layout.tags.dropFirst().enumerated() {
            report.sections.append(MetadataSection(id: "id3v2.\(index + 1)", title: "Additional ID3v2.\(extra.version) Tag", symbol: "music.note.list",
                                                   entries: ID3.entries(extra, sectionEditable: false), note: "Read-only. Clean removes it."))
        }
        if let v1 = layout.v1 {
            report.sections.append(MetadataSection(id: "id3v1", title: "ID3v1 Tag", symbol: "music.note", entries: ID3.v1Entries(v1),
                                                   note: "The old fixed-size tag at the end of the file. Fields are limited to 30 Latin characters."))
        }
        if let ape = layout.ape {
            report.sections.append(MetadataSection(id: "ape", title: "APE Tag", symbol: "tag",
                                                   entries: ape.items.map { MetadataEntry(key: "ape:\($0.0)", label: $0.0, value: $0.1) },
                                                   note: "Read-only. Clean removes it."))
        }
        return report
    }

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try Self.layout(data)
        let writer = try StreamWriter(url: destination)
        try writer.write(data.bytes(layout.audio.lowerBound, layout.audio.count))
        try writer.close()
        return []
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try Self.layout(data)
        guard edits.allSatisfy({ $0.sectionID == "id3v2" || $0.sectionID == "id3v1" }) else {
            throw MetadataError.unsupported("Only the ID3v2 and ID3v1 tags can be edited.")
        }
        let tag = try ID3.applying(edits.filter { $0.sectionID == "id3v2" }, to: layout.tags.first)
        let writer = try StreamWriter(url: destination)
        if !tag.frames.isEmpty { try writer.write(ID3.build(tag)) }
        // Extra ID3v2 tags (rare) are kept as they were.
        var offset = layout.tags.first?.size ?? 0
        for extra in layout.tags.dropFirst() {
            try writer.write(data.bytes(offset, extra.size))
            offset += extra.size
        }
        try writer.write(data.bytes(layout.audio.lowerBound, layout.audio.count))
        if let ape = layout.ape { try writer.write(data.bytes(ape.range.lowerBound, ape.range.count)) }
        if let v1 = layout.v1 {
            let v1Edits = edits.filter { $0.sectionID == "id3v1" }
            let updated = ID3.applyingV1(v1Edits, to: v1)
            let empty = updated.title.isEmpty && updated.artist.isEmpty && updated.album.isEmpty && updated.year.isEmpty
                && updated.comment.isEmpty && updated.track == nil && updated.genre == 255
            if !empty { try writer.write(ID3.buildV1(updated)) }
        }
        try writer.close()
        return []
    }
}

// MARK: - FLAC

struct FLACHandler: FormatHandler {
    struct Block {
        var type: Int
        var body: Data
    }

    struct Layout {
        var id3Size: Int
        var blocks: [Block]
        var audioStart: Int
    }

    static func layout(_ data: Data) throws -> Layout {
        var start = 0
        if let tag = try? ID3.parse(data) { start = tag.size }
        guard data.starts(with: "fLaC", at: start) else { throw MetadataError.corrupt("Not a FLAC file.") }
        var offset = start + 4
        var blocks: [Block] = []
        while data.has(offset, 4) {
            let header = data.byte(offset)
            let length = data.u24be(offset + 1)
            guard data.has(offset + 4, length) else { throw MetadataError.corrupt("A FLAC metadata block runs past the end of the file.") }
            blocks.append(Block(type: Int(header & 0x7F), body: data.bytes(offset + 4, length)))
            offset += 4 + length
            if header & 0x80 != 0 { break }
        }
        guard blocks.first?.type == 0 else { throw MetadataError.corrupt("The FLAC stream information block is missing.") }
        return Layout(id3Size: start, blocks: blocks, audioStart: offset)
    }

    struct Comments {
        var vendor: String
        var fields: [(String, String)]
    }

    static func parseComments(_ body: Data) -> Comments {
        guard body.count >= 8 else { return Comments(vendor: "", fields: []) }
        let vendorLength = body.u32le(0)
        guard body.has(4, vendorLength + 4) else { return Comments(vendor: "", fields: []) }
        let vendor = body.text(4, vendorLength)
        var cursor = 4 + vendorLength
        let count = body.u32le(cursor)
        cursor += 4
        var fields: [(String, String)] = []
        for _ in 0..<count where body.has(cursor, 4) {
            let length = body.u32le(cursor)
            guard body.has(cursor + 4, length) else { break }
            let text = String(decoding: body.bytes(cursor + 4, length), as: UTF8.self)
            cursor += 4 + length
            let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            fields.append((String(parts[0]).uppercased(), parts.count > 1 ? String(parts[1]) : ""))
        }
        return Comments(vendor: vendor, fields: fields)
    }

    static func buildComments(_ comments: Comments) -> Data {
        var writer = ByteWriter()
        let vendor = Data(comments.vendor.utf8)
        writer.u32le(vendor.count)
        writer.append(vendor)
        writer.u32le(comments.fields.count)
        for (key, value) in comments.fields {
            let field = Data("\(key)=\(value)".utf8)
            writer.u32le(field.count)
            writer.append(field)
        }
        return writer.data
    }

    static func pictureEntry(_ body: Data, key: String) -> MetadataEntry {
        guard body.count >= 32 else { return MetadataEntry(key: key, label: "Picture", value: "Damaged picture", removable: true) }
        let type = body.u32be(0)
        let mimeLength = body.u32be(4)
        let mime = body.text(8, min(mimeLength, body.count - 8))
        var cursor = 8 + mimeLength
        guard body.has(cursor, 4) else { return MetadataEntry(key: key, label: "Picture", value: mime, removable: true) }
        let descriptionLength = body.u32be(cursor)
        let description = body.has(cursor + 4, descriptionLength) ? body.text(cursor + 4, descriptionLength) : ""
        cursor += 4 + descriptionLength
        guard body.has(cursor, 20) else { return MetadataEntry(key: key, label: "Picture", value: mime, removable: true) }
        let width = body.u32be(cursor), height = body.u32be(cursor + 4)
        let dataLength = body.u32be(cursor + 16)
        let image = body.has(cursor + 20, dataLength) ? body.bytes(cursor + 20, dataLength) : nil
        let kind = type == 3 ? "Front cover" : type == 4 ? "Back cover" : "Picture type \(type)"
        let value = "\(kind) · \(mime) · \(width) × \(height) · \(Format.bytes(dataLength))" + (description.isEmpty ? "" : " · \(description)")
        return MetadataEntry(key: key, label: "Picture", value: value, removable: true, multiline: false, image: image)
    }

    static let labels: [String: String] = [
        "TITLE": "Title", "ARTIST": "Artist", "ALBUM": "Album", "ALBUMARTIST": "Album artist", "DATE": "Date", "TRACKNUMBER": "Track",
        "TRACKTOTAL": "Track total", "DISCNUMBER": "Disc", "GENRE": "Genre", "COMMENT": "Comment", "DESCRIPTION": "Description",
        "COMPOSER": "Composer", "PERFORMER": "Performer", "COPYRIGHT": "Copyright", "LICENSE": "License", "ORGANIZATION": "Label",
        "ISRC": "ISRC", "ENCODER": "Encoder", "ENCODED-BY": "Encoded by", "LYRICS": "Lyrics", "LOCATION": "Recording location",
        "CONTACT": "Contact", "BPM": "BPM",
    ]

    static let templates = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DATE", "TRACKNUMBER", "DISCNUMBER", "GENRE", "COMMENT",
                            "COMPOSER", "COPYRIGHT", "LYRICS"].map { FieldTemplate($0, labels[$0] ?? $0) }

    static func commentEntries(_ comments: Comments) -> [MetadataEntry] {
        var seen: [String: Int] = [:]
        var entries = comments.fields.map { key, value -> MetadataEntry in
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            let entryKey = occurrence > 0 ? "\(key)#\(occurrence)" : key
            return MetadataEntry(key: entryKey, label: labels[key] ?? Format.words(key.lowercased()), value: value, detail: key,
                                 editable: true, removable: true, multiline: key == "LYRICS" || value.count > 80)
        }
        entries.insert(MetadataEntry(key: "vendor", label: "Encoder (vendor)", value: comments.vendor, detail: "vendor string",
                                     editable: true, removable: false, multiline: false, highlight: .device), at: 0)
        return entries
    }

    func read(_ url: URL) async throws -> FormatReport {
        let data = try mappedData(url)
        let layout = try Self.layout(data)
        var report = FormatReport(format: "FLAC audio", canEdit: true, canClean: true)
        report.facts = await AudioFacts.read(url)
        let info = layout.blocks[0].body
        if info.count >= 18 {
            let sampleRate = Int(info.byte(10)) << 12 | Int(info.byte(11)) << 4 | Int(info.byte(12)) >> 4
            let channels = Int((info.byte(12) >> 1) & 0x07) + 1
            let bits = (Int(info.byte(12) & 0x01) << 4 | Int(info.byte(13)) >> 4) + 1
            let samples = Int(info.byte(13) & 0x0F) << 32 | info.u32be(14)
            if report.facts.isEmpty, sampleRate > 0 {
                report.facts = [Fact("Duration", Format.duration(Double(samples) / Double(sampleRate)), symbol: "clock"),
                                Fact("Audio", "\(Format.hertz(Double(sampleRate))) · \(Format.channels(channels)) · \(bits)-bit", symbol: "waveform")]
            }
        }
        let comments = layout.blocks.first { $0.type == 4 }.map { Self.parseComments($0.body) } ?? Comments(vendor: "", fields: [])
        report.sections.append(MetadataSection(id: "vorbis", title: "Vorbis Comments", symbol: "music.note.list",
                                               entries: Self.commentEntries(comments), templates: Self.templates,
                                               customFieldHint: "Field name, e.g. MOOD"))
        var pictures: [MetadataEntry] = []
        var other: [MetadataEntry] = []
        for (index, block) in layout.blocks.enumerated() {
            switch block.type {
            case 6: pictures.append(Self.pictureEntry(block.body, key: "block\(index)"))
            case 2:
                let id = block.body.count >= 4 ? block.body.fourCC(0) : "?"
                other.append(MetadataEntry(key: "block\(index)", label: "Application data (\(id))", value: Format.bytes(block.body.count), removable: true))
            case 5:
                other.append(MetadataEntry(key: "block\(index)", label: "Cue sheet", value: Format.bytes(block.body.count), removable: true))
            default: break
            }
        }
        if !pictures.isEmpty { report.sections.append(MetadataSection(id: "pictures", title: "Pictures", symbol: "photo", entries: pictures)) }
        if !other.isEmpty { report.sections.append(MetadataSection(id: "blocks", title: "Other Blocks", symbol: "square.stack.3d.up", entries: other)) }
        if layout.id3Size > 0 {
            if let tag = try? ID3.parse(data) {
                report.sections.append(MetadataSection(id: "id3", title: "ID3 Tag (non-standard)", symbol: "music.note.list",
                                                       entries: ID3.entries(tag, sectionEditable: false), note: "Read-only. Clean removes it."))
            }
        }
        return report
    }

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try Self.layout(data)
        // Keep only what playback needs: stream info and the seek table.
        try write(layout.blocks.filter { $0.type == 0 || $0.type == 3 }, data: data, audioStart: layout.audioStart, to: destination)
        return []
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        let data = try mappedData(source)
        let layout = try Self.layout(data)
        var blocks = layout.blocks
        let commentIndex = blocks.firstIndex { $0.type == 4 }
        var comments = commentIndex.map { Self.parseComments(blocks[$0].body) } ?? Comments(vendor: "", fields: [])
        let entries = Self.commentEntries(comments)
        var removed = Set<Int>()
        for edit in edits {
            switch edit.sectionID {
            case "vorbis":
                if edit.key == "vendor" {
                    comments.vendor = edit.newValue ?? ""
                } else if let position = entries.firstIndex(where: { $0.key == edit.key }) {
                    let fieldIndex = position - 1
                    if let value = edit.newValue {
                        comments.fields[fieldIndex].1 = value
                    } else {
                        comments.fields[fieldIndex].0 = ""
                    }
                } else if let value = edit.newValue {
                    let key = edit.key.uppercased().filter { $0 != "=" && $0.asciiValue.map { $0 >= 0x20 && $0 <= 0x7D } == true }
                    guard !key.isEmpty else { throw MetadataError.unsupported("Field names use plain letters, e.g. MOOD.") }
                    comments.fields.append((key, value))
                }
            case "pictures", "blocks":
                if edit.action == .remove, let index = Int(edit.key.dropFirst(5)) { removed.insert(index) }
            default:
                throw MetadataError.unsupported("This section is read-only.")
            }
        }
        comments.fields.removeAll { $0.0.isEmpty }
        let body = Self.buildComments(comments)
        if let commentIndex {
            blocks[commentIndex].body = body
        } else {
            blocks.insert(Block(type: 4, body: body), at: 1)
            removed = Set(removed.map { $0 >= 1 ? $0 + 1 : $0 })
        }
        blocks = blocks.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        try write(blocks, data: data, audioStart: layout.audioStart, to: destination)
        return []
    }

    private func write(_ blocks: [Block], data: Data, audioStart: Int, to destination: URL) throws {
        var writer = ByteWriter()
        writer.ascii("fLaC")
        for (index, block) in blocks.enumerated() {
            guard block.body.count < 1 << 24 else { throw MetadataError.writeFailed("A FLAC metadata block is too large.") }
            writer.u8(block.type | (index == blocks.count - 1 ? 0x80 : 0))
            writer.u24be(block.body.count)
            writer.append(block.body)
        }
        let stream = try StreamWriter(url: destination)
        try stream.write(writer.data)
        try stream.write(data.bytes(audioStart, data.count - audioStart))
        try stream.close()
    }
}
