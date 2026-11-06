import Foundation

/// Minimal ZIP reader/writer for Office and OpenDocument files: unchanged entries are copied in their
/// compressed form; replaced entries are deflated again. No ZIP64 or encryption.
struct ZipArchive {
    struct Entry {
        var name: String
        var method: Int
        var flags: Int
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var time: Int
        var date: Int
        var madeBy: Int
        var externalAttributes: Int
        var dataOffset: Int

        var modified: Date? {
            var components = DateComponents()
            components.year = 1980 + (date >> 9)
            components.month = (date >> 5) & 0x0F
            components.day = date & 0x1F
            components.hour = time >> 11
            components.minute = (time >> 5) & 0x3F
            components.second = (time & 0x1F) * 2
            return Calendar.current.date(from: components)
        }

        /// The DOS epoch (1980-01-01 00:00), which cleaned archives use for every entry.
        var hasNeutralDate: Bool { date == ZipArchive.neutralDate && time == 0 }
    }

    static let neutralDate = (1 << 5) | 1

    let data: Data
    let entries: [Entry]

    init(_ data: Data) throws {
        self.data = data
        // The end-of-central-directory record sits in the last 64 KB.
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        var index = data.count - 22
        while index >= searchStart {
            if data.byte(index) == 0x50, data.u32le(index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw MetadataError.corrupt("This isn't a valid ZIP-based document.") }
        let count = data.u16le(eocd + 10)
        var cursor = data.u32le(eocd + 16)
        guard count != 0xFFFF, cursor != 0xFFFF_FFFF else { throw MetadataError.unsupported("Very large (ZIP64) documents aren't supported.") }
        var entries: [Entry] = []
        for _ in 0..<count {
            guard data.has(cursor, 46), data.u32le(cursor) == 0x0201_4B50 else { throw MetadataError.corrupt("The document's file list is damaged.") }
            let nameLength = data.u16le(cursor + 28), extraLength = data.u16le(cursor + 30), commentLength = data.u16le(cursor + 32)
            let localOffset = data.u32le(cursor + 42)
            guard data.has(cursor + 46, nameLength), data.has(localOffset, 30) else { throw MetadataError.corrupt("The document's file list is damaged.") }
            let name = String(decoding: data.bytes(cursor + 46, nameLength), as: UTF8.self)
            let localNameLength = data.u16le(localOffset + 26), localExtraLength = data.u16le(localOffset + 28)
            let entry = Entry(name: name, method: data.u16le(cursor + 10), flags: data.u16le(cursor + 8), crc: UInt32(data.u32le(cursor + 16)),
                              compressedSize: data.u32le(cursor + 20), size: data.u32le(cursor + 24), time: data.u16le(cursor + 12),
                              date: data.u16le(cursor + 14), madeBy: data.u16le(cursor + 4), externalAttributes: data.u32le(cursor + 38),
                              dataOffset: localOffset + 30 + localNameLength + localExtraLength)
            guard entry.flags & 1 == 0 else { throw MetadataError.unsupported("Encrypted documents aren't supported.") }
            guard data.has(entry.dataOffset, entry.compressedSize) else { throw MetadataError.corrupt("A file inside the document is truncated.") }
            entries.append(entry)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    func contents(_ entry: Entry) throws -> Data {
        let stored = data.bytes(entry.dataOffset, entry.compressedSize)
        switch entry.method {
        case 0: return stored
        case 8:
            // Apple's "zlib" algorithm is raw DEFLATE, which is what ZIP stores.
            guard let inflated = try? (stored as NSData).decompressed(using: .zlib) as Data else {
                throw MetadataError.corrupt("Couldn't decompress \(entry.name).")
            }
            return inflated
        default:
            throw MetadataError.unsupported("\(entry.name) uses an unsupported compression method.")
        }
    }

    func contents(_ name: String) throws -> Data? {
        try entry(name).map(contents)
    }

    enum Change {
        case keep
        case replace(Data)
        case remove
    }

    /// Writes a new archive. With `neutralDates`, every entry gets the 1980 epoch and no file-system extras.
    func write(to url: URL, changes: [String: Change], neutralDates: Bool) throws {
        var body = ByteWriter()
        var central = ByteWriter()
        var count = 0
        for entry in entries {
            let change = changes[entry.name] ?? .keep
            if case .remove = change { continue }
            var method = entry.method, crc = entry.crc, size = entry.size
            var payload = data.bytes(entry.dataOffset, entry.compressedSize)
            if case .replace(let contents) = change {
                crc = CRC32.checksum(contents)
                size = contents.count
                if entry.method == 0 {
                    payload = contents
                } else {
                    guard let deflated = try? (contents as NSData).compressed(using: .zlib) as Data else {
                        throw MetadataError.writeFailed("Couldn't compress \(entry.name).")
                    }
                    payload = deflated
                    method = 8
                }
            }
            guard body.data.count < 0xFFFF_FFFF, payload.count < 0xFFFF_FFFF else {
                throw MetadataError.unsupported("Very large (ZIP64) documents aren't supported.")
            }
            let name = Data(entry.name.utf8)
            let flags = (entry.flags & 0x0806) | (entry.name.utf8.count != entry.name.count ? 0x0800 : 0)
            let time = neutralDates ? 0 : entry.time
            let date = neutralDates ? Self.neutralDate : entry.date
            let offset = body.data.count

            body.u32le(0x0403_4B50)
            body.u16le(20)
            body.u16le(flags)
            body.u16le(method)
            body.u16le(time)
            body.u16le(date)
            body.u32le(Int(crc))
            body.u32le(payload.count)
            body.u32le(size)
            body.u16le(name.count)
            body.u16le(0)
            body.append(name)
            body.append(payload)

            central.u32le(0x0201_4B50)
            central.u16le(neutralDates ? 20 : entry.madeBy)
            central.u16le(20)
            central.u16le(flags)
            central.u16le(method)
            central.u16le(time)
            central.u16le(date)
            central.u32le(Int(crc))
            central.u32le(payload.count)
            central.u32le(size)
            central.u16le(name.count)
            central.u16le(0)
            central.u16le(0)
            central.u16le(0)
            central.u16le(0)
            central.u32le(neutralDates ? 0 : entry.externalAttributes)
            central.u32le(offset)
            central.append(name)
            count += 1
        }
        var end = ByteWriter()
        end.u32le(0x0605_4B50)
        end.u16le(0)
        end.u16le(0)
        end.u16le(count)
        end.u16le(count)
        end.u32le(central.data.count)
        end.u32le(body.data.count)
        end.u16le(0)
        try (body.data + central.data + end.data).write(to: url)
    }
}
