import Foundation

// Small helpers for reading and writing binary file formats. Offsets are always relative to the
// start of the Data value, whatever its startIndex.

extension Data {
    func byte(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func bytes(_ offset: Int, _ count: Int) -> Data {
        subdata(in: (startIndex + offset)..<(startIndex + offset + count))
    }

    func has(_ offset: Int, _ count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset + count <= self.count
    }

    func u16be(_ offset: Int) -> Int { Int(byte(offset)) << 8 | Int(byte(offset + 1)) }
    func u16le(_ offset: Int) -> Int { Int(byte(offset + 1)) << 8 | Int(byte(offset)) }
    func u24be(_ offset: Int) -> Int { Int(byte(offset)) << 16 | Int(byte(offset + 1)) << 8 | Int(byte(offset + 2)) }

    func u32be(_ offset: Int) -> Int {
        Int(byte(offset)) << 24 | Int(byte(offset + 1)) << 16 | Int(byte(offset + 2)) << 8 | Int(byte(offset + 3))
    }

    func u32le(_ offset: Int) -> Int {
        Int(byte(offset + 3)) << 24 | Int(byte(offset + 2)) << 16 | Int(byte(offset + 1)) << 8 | Int(byte(offset))
    }

    func u64be(_ offset: Int) -> Int { u32be(offset) << 32 | u32be(offset + 4) }

    /// Reads a big-endian unsigned integer of 0, 2, 4 or 8 bytes (as used by ISO box fields).
    func uintBE(_ offset: Int, size: Int) -> Int {
        switch size {
        case 0: return 0
        case 1: return Int(byte(offset))
        case 2: return u16be(offset)
        case 4: return u32be(offset)
        case 8: return u64be(offset)
        default: return 0
        }
    }

    /// Four-character code (chunk/box/frame id) as text.
    func fourCC(_ offset: Int, length: Int = 4) -> String {
        String(decoding: bytes(offset, length), as: UTF8.self)
    }

    func starts(with text: String, at offset: Int = 0) -> Bool {
        let probe = Data(text.utf8)
        return has(offset, probe.count) && bytes(offset, probe.count) == probe
    }

    func firstIndex(of byte: UInt8, from offset: Int, before end: Int? = nil) -> Int? {
        let limit = Swift.min(end ?? count, count)
        var index = offset
        while index < limit {
            if self.byte(index) == byte { return index }
            index += 1
        }
        return nil
    }

    /// Text decoded as UTF-8, falling back to Latin-1, with trailing NULs and spaces trimmed.
    func text(_ offset: Int, _ length: Int) -> String {
        Data.decodeText(bytes(offset, length))
    }

    static func decodeText(_ data: Data) -> String {
        var slice = data
        while let last = slice.last, last == 0 { slice = slice.dropLast() }
        let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var hexPreview: String {
        let head = prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > 24 ? head + " …" : head
    }
}

/// Builds binary output with explicit endianness.
struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    mutating func u16be(_ value: Int) { u8(value >> 8); u8(value) }
    mutating func u16le(_ value: Int) { u8(value); u8(value >> 8) }
    mutating func u24be(_ value: Int) { u8(value >> 16); u8(value >> 8); u8(value) }
    mutating func u32be(_ value: Int) { u8(value >> 24); u8(value >> 16); u8(value >> 8); u8(value) }
    mutating func u32le(_ value: Int) { u8(value); u8(value >> 8); u8(value >> 16); u8(value >> 24) }
    mutating func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }
}

/// Writes a file in pieces so large media payloads can be copied straight from a mapped source.
final class StreamWriter {
    private let handle: FileHandle
    private(set) var written = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw MetadataError.writeFailed("Could not create \(url.lastPathComponent).")
        }
        self.handle = handle
    }

    func write(_ data: Data) throws {
        // Large slices go out in 8 MB pieces to keep memory flat with mapped sources.
        let piece = 8 << 20
        var offset = 0
        while offset < data.count {
            let end = Swift.min(offset + piece, data.count)
            try handle.write(contentsOf: data.bytes(offset, end - offset))
            offset = end
        }
        written += data.count
    }

    func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data, initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return ~crc
    }
}

func mappedData(_ url: URL) throws -> Data {
    do {
        return try Data(contentsOf: url, options: .alwaysMapped)
    } catch {
        throw MetadataError.unreadable("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func hertz(_ rate: Double) -> String {
        rate >= 1000 ? String(format: rate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", rate / 1000)
            : String(format: "%.0f Hz", rate)
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) channels"
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Dates are shown and edited as `yyyy-MM-dd HH:mm:ss` in local time.
    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = dateFormatter.date(from: trimmed) { return date }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy:MM:dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// "DateTimeOriginal" → "Date Time Original", "lastModifiedBy" → "Last Modified By".
    static func words(_ name: String) -> String {
        var result = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next.isLowercase) { result.append(" ") }
            }
            result.append(index == 0 ? Character(character.uppercased()) : character)
        }
        return result.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
}
