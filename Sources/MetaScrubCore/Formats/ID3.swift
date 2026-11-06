import Foundation

/// ID3v2 (2.2–2.4) and ID3v1 tags, as used by MP3 files (and inside some WAV/AIFF files).
enum ID3 {
    struct Frame {
        var id: String
        /// Status and format flags as stored; zero for frames MetaScrub writes.
        var flags: Int
        /// The frame body with unsynchronisation and data-length prefixes already removed.
        var body: Data
        /// True when the body is still compressed or encrypted and can't be interpreted.
        var opaque: Bool
    }

    struct Tag {
        var version: Int
        var frames: [Frame]
        /// Total bytes the tag occupies in the file, header and footer included.
        var size: Int
    }

    static func syncsafe(_ data: Data, _ offset: Int) -> Int {
        Int(data.byte(offset) & 0x7F) << 21 | Int(data.byte(offset + 1) & 0x7F) << 14 | Int(data.byte(offset + 2) & 0x7F) << 7
            | Int(data.byte(offset + 3) & 0x7F)
    }

    static func syncsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    static func removeUnsynchronisation(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if !(previous == 0xFF && byte == 0x00) { out.append(byte) }
            previous = byte
        }
        return out
    }

    /// Parses an ID3v2 tag starting at `offset`; nil when there is none.
    static func parse(_ data: Data, at offset: Int = 0) throws -> Tag? {
        guard data.has(offset, 10), data.starts(with: "ID3", at: offset) else { return nil }
        let version = Int(data.byte(offset + 3))
        let flags = data.byte(offset + 5)
        let bodySize = syncsafe(data, offset + 6)
        let footer = version == 4 && flags & 0x10 != 0 ? 10 : 0
        let total = 10 + bodySize + footer
        guard version >= 2 && version <= 4, data.has(offset, 10 + bodySize) else {
            throw MetadataError.corrupt("The ID3 tag is damaged or uses an unknown version.")
        }
        var body = data.bytes(offset + 10, bodySize)
        if flags & 0x80 != 0 && version < 4 { body = removeUnsynchronisation(body) }
        var cursor = 0
        if flags & 0x40 != 0 && version >= 3, body.has(0, 4) {
            cursor = version == 3 ? body.u32be(0) + 4 : syncsafe(body, 0)
        }
        var frames: [Frame] = []
        let headerSize = version == 2 ? 6 : 10
        while body.has(cursor, headerSize) {
            let idLength = version == 2 ? 3 : 4
            let id = body.fourCC(cursor, length: idLength)
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }), body.byte(cursor) != 0 else { break }  // padding
            let size: Int
            var frameFlags = 0
            switch version {
            case 2: size = body.u24be(cursor + 3)
            case 3: size = body.u32be(cursor + 4); frameFlags = body.u16be(cursor + 8)
            default: size = syncsafe(body, cursor + 4); frameFlags = body.u16be(cursor + 8)
            }
            cursor += headerSize
            guard size >= 0, body.has(cursor, size) else { break }
            var frameBody = body.bytes(cursor, size)
            cursor += size
            var opaque = false
            if version == 4 {
                if frameFlags & 0x0002 != 0 || flags & 0x80 != 0 { frameBody = removeUnsynchronisation(frameBody) }
                if frameFlags & 0x0001 != 0, frameBody.count >= 4 { frameBody = frameBody.dropFirst(4) }
                if frameFlags & 0x0040 != 0, !frameBody.isEmpty { frameBody = frameBody.dropFirst(1) }
                opaque = frameFlags & 0x000C != 0
                frameFlags &= ~0x0043
            } else if version == 3 {
                if frameFlags & 0x0020 != 0, !frameBody.isEmpty { frameBody = frameBody.dropFirst(1) }
                opaque = frameFlags & 0x00C0 != 0
                frameFlags &= ~0x0020
            }
            frames.append(Frame(id: id, flags: frameFlags, body: Data(frameBody), opaque: opaque))
        }
        return Tag(version: version, frames: frames, size: total)
    }

    // MARK: Text encoding

    static func decode(_ data: Data, encoding: UInt8) -> String {
        let string: String?
        switch encoding {
        case 1:
            string = String(data: data, encoding: .utf16)
        case 2:
            string = String(data: data, encoding: .utf16BigEndian)
        case 3:
            string = String(data: data, encoding: .utf8)
        default:
            string = String(data: data, encoding: .isoLatin1)
        }
        return (string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Splits `data` at the first terminator for the encoding (one NUL, or two aligned NULs for UTF-16).
    static func splitTerminated(_ data: Data, encoding: UInt8) -> (Data, Data) {
        let wide = encoding == 1 || encoding == 2
        var index = 0
        while index < data.count {
            if wide {
                if index + 1 < data.count, data.byte(index) == 0, data.byte(index + 1) == 0 {
                    return (data.bytes(0, index), data.bytes(index + 2, data.count - index - 2))
                }
                index += 2
            } else {
                if data.byte(index) == 0 { return (data.bytes(0, index), data.bytes(index + 1, data.count - index - 1)) }
                index += 1
            }
        }
        return (data, Data())
    }

    static func encode(_ text: String, version: Int) -> (UInt8, Data) {
        if text.unicodeScalars.allSatisfy({ $0.value < 0x100 }), let latin = text.data(using: .isoLatin1) { return (0, latin) }
        if version == 4 { return (3, Data(text.utf8)) }
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return (1, data)
    }

    static func terminator(_ encoding: UInt8) -> Data { encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0]) }

    // MARK: Frame meaning

    static let names: [String: String] = [
        "TIT2": "Title", "TPE1": "Artist", "TALB": "Album", "TPE2": "Album artist", "TYER": "Year", "TDRC": "Recording date",
        "TRCK": "Track", "TPOS": "Disc", "TCON": "Genre", "TCOM": "Composer", "TEXT": "Lyricist", "TCOP": "Copyright",
        "TPUB": "Publisher", "TENC": "Encoded by", "TSSE": "Encoder settings", "TBPM": "BPM", "TKEY": "Initial key",
        "TLAN": "Language", "TIT1": "Grouping", "TIT3": "Subtitle", "TPE3": "Conductor", "TPE4": "Remixed by",
        "TOPE": "Original artist", "TOAL": "Original album", "TORY": "Original year", "TDOR": "Original release date",
        "TDRL": "Release date", "TDEN": "Encoding date", "TDTG": "Tagging date", "TSRC": "ISRC", "TMED": "Media type",
        "TOWN": "File owner", "TRSN": "Radio station", "TFLT": "File type", "TLEN": "Length (ms)", "TSOA": "Album sort",
        "TSOP": "Artist sort", "TSOT": "Title sort", "TSO2": "Album artist sort", "TCMP": "Compilation", "TDAT": "Date",
        "TIME": "Time", "TMOO": "Mood", "TPRO": "Produced notice", "TCAT": "Podcast category", "TDES": "Podcast description",
        "COMM": "Comment", "USLT": "Lyrics", "APIC": "Picture", "PIC": "Picture", "WXXX": "Link", "WOAR": "Artist website",
        "WCOP": "Copyright info", "WOAS": "Source website", "WPUB": "Publisher website", "WCOM": "Buy link", "WOAF": "File website",
        "PRIV": "Private data", "GEOB": "Embedded object", "UFID": "Unique file ID", "POPM": "Rating", "PCNT": "Play count",
        "MCDI": "CD identifier", "TXXX": "Custom", "SYLT": "Synced lyrics", "CHAP": "Chapter", "CTOC": "Table of contents",
        "TT2": "Title", "TP1": "Artist", "TAL": "Album", "TYE": "Year", "TRK": "Track", "TCO": "Genre", "COM": "Comment",
        "TEN": "Encoded by", "TP2": "Album artist", "TCM": "Composer", "TPA": "Disc", "TSS": "Encoder settings",
    ]

    static let genres = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age",
                         "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
                         "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion",
                         "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
                         "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
                         "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
                         "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
                         "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal",
                         "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"]

    struct Described {
        var key: String
        var label: String
        var value: String
        var editable: Bool
        var image: Data?
    }

    /// Key that identifies a frame for edits: the id, plus description/language for frames that repeat.
    static func describe(_ frame: Frame, version: Int, occurrence: Int) -> Described {
        let id = frame.id
        let name = names[id] ?? id
        let body = frame.body
        let suffix = occurrence > 0 ? "#\(occurrence)" : ""
        guard !frame.opaque, !body.isEmpty else {
            return Described(key: id + suffix, label: name, value: frame.opaque ? "Compressed or encrypted frame" : "", editable: false)
        }
        let encoding = body.byte(0)
        let rest = body.dropFirst()
        let writable = version >= 3
        switch id {
        case "TXXX", "TXX":
            let (description, value) = splitTerminated(Data(rest), encoding: encoding)
            let label = decode(description, encoding: encoding)
            return Described(key: "TXXX:\(label)" + suffix, label: label.isEmpty ? "Custom" : label,
                             value: decode(value, encoding: encoding), editable: writable)
        case "COMM", "USLT", "COM", "ULT":
            guard rest.count >= 3 else { return Described(key: id + suffix, label: name, value: "", editable: false) }
            let (description, value) = splitTerminated(Data(rest.dropFirst(3)), encoding: encoding)
            let label = decode(description, encoding: encoding)
            let text = decode(value, encoding: encoding)
            let key = label.isEmpty ? id + suffix : "\(id):\(label)" + suffix
            let title = label.isEmpty ? name : "\(name) (\(label))"
            return Described(key: key, label: title, value: text, editable: writable && !label.hasPrefix("iTun"))
        case "APIC", "PIC":
            var cursor = Data(rest)
            var mime = "image"
            if id == "PIC" {
                mime = String(decoding: cursor.prefix(3), as: UTF8.self)
                cursor = cursor.dropFirst(3)
            } else {
                let (mimeData, after) = splitTerminated(cursor, encoding: 0)
                mime = String(decoding: mimeData, as: UTF8.self)
                cursor = after
            }
            let pictureType = cursor.first.map(Int.init) ?? 0
            let (description, image) = splitTerminated(Data(cursor.dropFirst()), encoding: encoding)
            let text = decode(description, encoding: encoding)
            let kind = pictureType == 3 ? "Front cover" : pictureType == 4 ? "Back cover" : "Picture type \(pictureType)"
            let value = "\(kind) · \(mime) · \(Format.bytes(image.count))" + (text.isEmpty ? "" : " · \(text)")
            return Described(key: "APIC" + suffix, label: name, value: value, editable: false, image: image)
        case "WXXX", "WXX":
            let (description, url) = splitTerminated(Data(rest), encoding: encoding)
            let label = decode(description, encoding: encoding)
            return Described(key: "WXXX" + suffix, label: label.isEmpty ? name : "Link (\(label))",
                             value: decode(url, encoding: 0), editable: writable && label.isEmpty)
        case "PRIV", "UFID":
            let (owner, payload) = splitTerminated(body, encoding: 0)
            return Described(key: id + suffix, label: name, value: "\(String(decoding: owner, as: UTF8.self)) · \(Format.bytes(payload.count))",
                             editable: false)
        case "POPM":
            let (email, payload) = splitTerminated(body, encoding: 0)
            let rating = payload.first.map { "\($0)/255" } ?? ""
            return Described(key: id + suffix, label: name, value: "\(rating) \(String(decoding: email, as: UTF8.self))", editable: false)
        default:
            if id.hasPrefix("T") {
                var value = decode(Data(rest), encoding: encoding).replacingOccurrences(of: "\0", with: "; ")
                if id == "TCON" || id == "TCO" { value = genreName(value) }
                return Described(key: id + suffix, label: name, value: value, editable: writable)
            }
            if id.hasPrefix("W") {
                return Described(key: id + suffix, label: name, value: decode(body, encoding: 0), editable: writable)
            }
            return Described(key: id + suffix, label: name, value: "\(Format.bytes(body.count)) of data", editable: false)
        }
    }

    /// "(17)" or "17" → "Rock"; other text unchanged.
    static func genreName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let number = Int(trimmed), number >= 0, number < genres.count { return genres[number] }
        return value
    }

    /// Entries for a whole tag; repeated keys get `#1`, `#2`… so every entry stays addressable.
    static func entries(_ tag: Tag, sectionEditable: Bool) -> [MetadataEntry] {
        var seen: [String: Int] = [:]
        return tag.frames.map { frame in
            let base = describe(frame, version: tag.version, occurrence: 0).key
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            let described = describe(frame, version: tag.version, occurrence: occurrence)
            return MetadataEntry(key: described.key, label: described.label, value: described.value, detail: frame.id,
                                 editable: sectionEditable && described.editable, removable: sectionEditable,
                                 multiline: frame.id == "USLT" || described.value.count > 80, image: described.image)
        }
    }

    // MARK: Writing

    static func textFrame(_ id: String, _ value: String, version: Int) -> Frame {
        let (encoding, data) = encode(value, version: version)
        switch id {
        case "COMM", "USLT":
            return Frame(id: id, flags: 0, body: Data([encoding]) + Data("eng".utf8) + terminator(encoding) + data, opaque: false)
        case "WXXX":
            return Frame(id: id, flags: 0, body: Data([0, 0]) + Data(value.utf8), opaque: false)
        default:
            if id.hasPrefix("TXXX:") {
                // Description and value share one encoding.
                let description = String(id.dropFirst(5))
                let shared = encode(description + value, version: version).0
                let body = Data([shared]) + encoded(description, shared) + terminator(shared) + encoded(value, shared)
                return Frame(id: "TXXX", flags: 0, body: body, opaque: false)
            }
            if id.hasPrefix("W") { return Frame(id: id, flags: 0, body: Data(value.utf8), opaque: false) }
            return Frame(id: id, flags: 0, body: Data([encoding]) + data, opaque: false)
        }
    }

    private static func encoded(_ text: String, _ encoding: UInt8) -> Data {
        switch encoding {
        case 0: return text.data(using: .isoLatin1) ?? Data()
        case 3: return Data(text.utf8)
        default: return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        }
    }

    /// Applies edits to a tag (a new v2.3 tag when there is none). Keys come from `entries`.
    static func applying(_ edits: [MetadataEdit], to tag: Tag?) throws -> Tag {
        var result = tag ?? Tag(version: 3, frames: [], size: 0)
        guard result.version >= 3 else { throw MetadataError.unsupported("ID3v2.2 tags are read-only. Clean the file to remove it.") }
        let current = entries(result, sectionEditable: true)
        for edit in edits {
            // Entries map one-to-one onto frames, so the entry's position is the frame's.
            if let frameIndex = current.firstIndex(where: { $0.key == edit.key }) {
                switch edit.action {
                case .remove:
                    result.frames[frameIndex].body = Data()
                    result.frames[frameIndex].id = ""
                case .set(let value):
                    let id = result.frames[frameIndex].id
                    var key = edit.key.split(separator: "#").first.map(String.init) ?? edit.key
                    if id == "COMM" || id == "USLT" {
                        // Keep the original language and description.
                        let old = result.frames[frameIndex].body
                        let (encoding, data) = encode(value, version: result.version)
                        let (description, _) = splitTerminated(Data(old.dropFirst(4)), encoding: old.first ?? 0)
                        let descriptionText = decode(description, encoding: old.first ?? 0)
                        let language = old.count >= 4 ? old.bytes(1, 3) : Data("eng".utf8)
                        result.frames[frameIndex].body = Data([encoding]) + language + encoded(descriptionText, encoding)
                            + terminator(encoding) + data
                        result.frames[frameIndex].flags = 0
                        continue
                    }
                    if id != "TXXX" { key = id }
                    result.frames[frameIndex] = textFrame(key, value, version: result.version)
                }
            } else if case .set(let value) = edit.action {
                var id = edit.key
                if id == "TYER" && result.version == 4 { id = "TDRC" }
                if id == "TDRC" && result.version == 3 { id = "TYER" }
                // Anything that isn't a frame ID becomes a custom text field.
                if !id.hasPrefix("TXXX:") && !(id.count == 4 && id.allSatisfy { $0.isUppercase || $0.isNumber }) { id = "TXXX:" + id }
                result.frames.append(textFrame(id, value, version: result.version))
            }
        }
        result.frames.removeAll { $0.id.isEmpty }
        return result
    }

    static func build(_ tag: Tag, padding: Int = 512) -> Data {
        var frames = Data()
        for frame in tag.frames {
            var writer = ByteWriter()
            writer.ascii(frame.id)
            if tag.version == 4 {
                writer.append(Data(syncsafeBytes(frame.body.count)))
            } else {
                writer.u32be(frame.body.count)
            }
            writer.u16be(frame.flags)
            writer.append(frame.body)
            frames.append(writer.data)
        }
        var writer = ByteWriter()
        writer.ascii("ID3")
        writer.u8(tag.version)
        writer.u8(0)
        writer.u8(0)
        writer.append(Data(syncsafeBytes(frames.count + padding)))
        writer.append(frames)
        writer.zeros(padding)
        return writer.data
    }

    // MARK: ID3v1

    struct V1 {
        var title = "", artist = "", album = "", year = "", comment = ""
        var track: Int?
        var genre: Int = 255
    }

    static func parseV1(_ data: Data) -> V1? {
        guard data.count >= 128, data.starts(with: "TAG", at: data.count - 128) else { return nil }
        let base = data.count - 128
        var tag = V1()
        tag.title = data.text(base + 3, 30)
        tag.artist = data.text(base + 33, 30)
        tag.album = data.text(base + 63, 30)
        tag.year = data.text(base + 93, 4)
        if data.byte(base + 125) == 0 && data.byte(base + 126) != 0 {
            tag.comment = data.text(base + 97, 28)
            tag.track = Int(data.byte(base + 126))
        } else {
            tag.comment = data.text(base + 97, 30)
        }
        tag.genre = Int(data.byte(base + 127))
        return tag
    }

    static func v1Entries(_ tag: V1) -> [MetadataEntry] {
        var entries: [(String, String, String)] = [
            ("v1:title", "Title", tag.title), ("v1:artist", "Artist", tag.artist), ("v1:album", "Album", tag.album),
            ("v1:year", "Year", tag.year), ("v1:comment", "Comment", tag.comment),
        ]
        if let track = tag.track { entries.append(("v1:track", "Track", "\(track)")) }
        if tag.genre < genres.count { entries.append(("v1:genre", "Genre", genres[tag.genre])) }
        // The genre is a number into a fixed list, so it can only be removed, not typed.
        return entries.filter { !$0.2.isEmpty }.map {
            MetadataEntry(key: $0.0, label: $0.1, value: $0.2, editable: $0.0 != "v1:genre", removable: true, multiline: false)
        }
    }

    static func applyingV1(_ edits: [MetadataEdit], to tag: V1) -> V1 {
        var tag = tag
        for edit in edits {
            let value = edit.newValue ?? ""
            switch edit.key {
            case "v1:title": tag.title = value
            case "v1:artist": tag.artist = value
            case "v1:album": tag.album = value
            case "v1:year": tag.year = value
            case "v1:comment": tag.comment = value
            case "v1:track": tag.track = Int(value)
            case "v1:genre": tag.genre = genres.firstIndex { $0.caseInsensitiveCompare(value) == .orderedSame } ?? (Int(value) ?? 255)
            default: break
            }
        }
        return tag
    }

    static func buildV1(_ tag: V1) -> Data {
        func field(_ text: String, _ length: Int) -> Data {
            var data = (text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(length)
            data.append(Data(count: length - data.count))
            return Data(data)
        }
        var data = Data("TAG".utf8)
        data += field(tag.title, 30) + field(tag.artist, 30) + field(tag.album, 30) + field(tag.year, 4)
        if let track = tag.track {
            data += field(tag.comment, 28) + Data([0, UInt8(clamping: track)])
        } else {
            data += field(tag.comment, 30)
        }
        data.append(UInt8(clamping: tag.genre))
        return data
    }

    // MARK: APEv2

    /// Size and items of an APEv2 tag that ends at `end` (before any ID3v1 tag), if present.
    static func parseAPE(_ data: Data, end: Int) -> (start: Int, items: [(String, String)])? {
        guard end >= 32, data.starts(with: "APETAGEX", at: end - 32) else { return nil }
        let footer = end - 32
        let size = data.u32le(footer + 12)
        let count = data.u32le(footer + 16)
        let flags = data.u32le(footer + 20)
        let hasHeader = flags & 0x8000_0000 != 0
        let itemsStart = end - size
        let start = itemsStart - (hasHeader ? 32 : 0)
        guard start >= 0, size >= 32 else { return nil }
        var items: [(String, String)] = []
        var cursor = itemsStart
        for _ in 0..<count where cursor + 8 < footer {
            let length = data.u32le(cursor)
            let itemFlags = data.u32le(cursor + 4)
            guard let keyEnd = data.firstIndex(of: 0, from: cursor + 8, before: footer) else { break }
            let key = data.text(cursor + 8, keyEnd - cursor - 8)
            guard data.has(keyEnd + 1, length) else { break }
            let isText = (itemFlags >> 1) & 0x3 == 0
            items.append((key, isText ? data.text(keyEnd + 1, length) : "\(Format.bytes(length)) of data"))
            cursor = keyEnd + 1 + length
        }
        return (start, items)
    }
}
