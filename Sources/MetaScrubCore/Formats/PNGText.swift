import Foundation

/// PNG text chunks (tEXt, zTXt, iTXt), read and written directly. ImageIO only reports a fixed list of
/// keywords, so custom ones (such as the workflows AI image generators save) would otherwise be invisible
/// and lost when the image is re-saved.
enum PNGText {
    struct Chunk: Equatable {
        var type: String
        var keyword: String
        var text: String
        /// The chunk exactly as stored; nil once edited, so it is written fresh.
        var raw: Data?

        var isXMP: Bool { keyword == PNGText.xmpKeyword }
    }

    static let xmpKeyword = "XML:com.adobe.xmp"
    static let textTypes: Set<String> = ["tEXt", "zTXt", "iTXt"]

    /// Text chunks in file order (XMP included; callers filter it out where ImageIO handles it).
    static func read(_ data: Data) -> [Chunk] {
        var chunks: [Chunk] = []
        forEachChunk(data) { type, payload, raw in
            guard textTypes.contains(type), let chunk = parse(type, payload, raw: raw) else { return }
            chunks.append(chunk)
        }
        return chunks
    }

    private static func forEachChunk(_ data: Data, _ body: (String, Data, Data) -> Void) {
        guard data.count >= 8, data.bytes(0, 8) == PNGScrubber.signature else { return }
        var offset = 8
        while offset + 12 <= data.count {
            let length = data.u32be(offset)
            guard data.has(offset, 12 + length) else { return }
            let type = data.fourCC(offset + 4)
            body(type, data.bytes(offset + 8, length), data.bytes(offset, 12 + length))
            offset += 12 + length
            if type == "IEND" { return }
        }
    }

    private static func parse(_ type: String, _ payload: Data, raw: Data) -> Chunk? {
        guard let keywordEnd = payload.firstIndex(of: 0, from: 0) else { return nil }
        let keyword = String(data: payload.bytes(0, keywordEnd), encoding: .isoLatin1) ?? ""
        let rest = payload.bytes(keywordEnd + 1, payload.count - keywordEnd - 1)
        switch type {
        case "tEXt":
            return Chunk(type: type, keyword: keyword, text: String(data: rest, encoding: .isoLatin1) ?? "", raw: raw)
        case "zTXt":
            guard let first = rest.first, first == 0, let inflated = inflate(rest.dropFirst()) else { return nil }
            return Chunk(type: type, keyword: keyword, text: String(data: inflated, encoding: .isoLatin1) ?? "", raw: raw)
        default:
            // iTXt: compression flag, method, language tag, translated keyword, then UTF-8 text.
            guard rest.count >= 2 else { return nil }
            let compressed = rest.byte(0) == 1
            var cursor = 2
            guard let languageEnd = rest.firstIndex(of: 0, from: cursor) else { return nil }
            cursor = languageEnd + 1
            guard let translatedEnd = rest.firstIndex(of: 0, from: cursor) else { return nil }
            cursor = translatedEnd + 1
            var body = rest.bytes(cursor, rest.count - cursor)
            if compressed {
                guard let inflated = inflate(body) else { return nil }
                body = inflated
            }
            return Chunk(type: type, keyword: keyword, text: String(decoding: body, as: UTF8.self), raw: raw)
        }
    }

    /// Unwraps a zlib stream (2-byte header, raw DEFLATE, Adler-32), which is what PNG compresses with.
    private static func inflate(_ data: Data) -> Data? {
        let stream = Data(data)
        guard stream.count > 6 else { return nil }
        return try? (stream.bytes(2, stream.count - 6) as NSData).decompressed(using: .zlib) as Data
    }

    /// The chunk as bytes: the original when unchanged, else tEXt (Latin-1 text) or uncompressed iTXt (UTF-8).
    static func encode(_ chunk: Chunk) -> Data {
        if let raw = chunk.raw { return raw }
        let keyword = chunk.keyword.data(using: .isoLatin1) ?? Data(chunk.keyword.utf8)
        if let latin = chunk.text.data(using: .isoLatin1) {
            return PNGScrubber.chunk("tEXt", keyword + Data([0]) + latin)
        }
        return PNGScrubber.chunk("iTXt", keyword + Data([0, 0, 0, 0, 0]) + Data(chunk.text.utf8))
    }

    /// Edit keys are `png:<keyword>`, with `#n` for the second and later chunks of the same keyword.
    static func keys(_ chunks: [Chunk]) -> [String] {
        var seen: [String: Int] = [:]
        return chunks.map { chunk in
            let occurrence = seen[chunk.keyword, default: 0]
            seen[chunk.keyword] = occurrence + 1
            return "png:\(chunk.keyword)" + (occurrence > 0 ? "#\(occurrence)" : "")
        }
    }

    static func applying(_ edits: [MetadataEdit], to chunks: [Chunk]) throws -> [Chunk] {
        var result: [Chunk?] = chunks
        let keys = keys(chunks)
        for edit in edits {
            if let index = keys.firstIndex(of: edit.key) {
                if let value = edit.newValue {
                    result[index]?.text = value
                    result[index]?.raw = nil
                } else {
                    result[index] = nil
                }
            } else if let value = edit.newValue {
                let keyword = String(edit.key.dropFirst(edit.key.hasPrefix("png:") ? 4 : 0)).trimmingCharacters(in: .whitespaces)
                guard (1...79).contains(keyword.count), keyword.data(using: .isoLatin1) != nil, !keyword.contains("\u{0}") else {
                    throw MetadataError.unsupported("PNG text names are 1–79 plain characters, e.g. Comment.")
                }
                result.append(Chunk(type: "tEXt", keyword: keyword, text: value, raw: nil))
            }
        }
        return result.compactMap { $0 }
    }

    /// Rewrites `png` so its text chunks are exactly `chunks` (placed after the header), keeping the
    /// XMP chunk already in `png` (ImageIO writes that one when other fields are edited).
    static func replacingText(in png: Data, with chunks: [Chunk]) throws -> Data {
        guard png.count >= 8, png.bytes(0, 8) == PNGScrubber.signature else { throw MetadataError.corrupt("Not a PNG file.") }
        var out = PNGScrubber.signature
        var placed = false
        forEachChunk(png) { type, payload, raw in
            if textTypes.contains(type), parse(type, payload, raw: raw)?.isXMP != true { return }
            out.append(raw)
            if type == "IHDR" && !placed {
                for chunk in chunks where !chunk.isXMP { out.append(encode(chunk)) }
                placed = true
            }
        }
        guard placed else { throw MetadataError.corrupt("The PNG header is missing.") }
        return out
    }
}
