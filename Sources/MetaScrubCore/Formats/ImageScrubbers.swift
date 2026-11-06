import Foundation

// Lossless metadata removal for image containers: the compressed picture data is copied as is and
// only metadata blocks are dropped, so nothing is re-encoded.

enum JPEGScrubber {
    /// Keeps the image segments (tables, frame and scan data), the JFIF header without its thumbnail, the
    /// Adobe colour-transform segment and, if asked, the ICC profile. Drops EXIF, XMP, IPTC/Photoshop,
    /// comments, MPF previews and anything after the end-of-image marker.
    static func clean(_ data: Data, orientation: Int?, keepICC: Bool) throws -> Data {
        guard data.count > 4, data.byte(0) == 0xFF, data.byte(1) == 0xD8 else { throw MetadataError.corrupt("Not a JPEG file.") }
        var out = Data([0xFF, 0xD8])
        var offset = 2
        var pendingOrientation = (orientation ?? 1) != 1 ? orientation : nil

        func keep(_ segment: Data) {
            if let value = pendingOrientation {
                out.append(orientationSegment(value))
                pendingOrientation = nil
            }
            out.append(segment)
        }

        while offset + 1 < data.count {
            guard data.byte(offset) == 0xFF else { throw MetadataError.corrupt("Unexpected data at byte \(offset).") }
            var markerAt = offset
            while markerAt + 1 < data.count && data.byte(markerAt + 1) == 0xFF { markerAt += 1 }  // fill bytes
            guard markerAt + 1 < data.count else { break }
            let marker = data.byte(markerAt + 1)
            offset = markerAt + 2
            if marker == 0xD9 {
                out.append(contentsOf: [0xFF, 0xD9])
                return out
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                out.append(contentsOf: [0xFF, marker])
                continue
            }
            guard data.has(offset, 2) else { throw MetadataError.corrupt("The JPEG file is truncated.") }
            let length = data.u16be(offset)
            guard length >= 2, data.has(offset, length) else { throw MetadataError.corrupt("A JPEG segment runs past the end of the file.") }
            let segment = data.bytes(markerAt, 2 + length)
            let payload = data.bytes(offset + 2, length - 2)
            offset += length

            switch marker {
            case 0xE0:
                // JFIF carries density only; rebuild it without the optional thumbnail. JFXX (thumbnails) and others go.
                if payload.starts(with: "JFIF\u{0}") && payload.count >= 12 {
                    var jfif = ByteWriter()
                    jfif.u16be(0xFFE0)
                    jfif.u16be(2 + 14)
                    jfif.append(payload.bytes(0, 12))
                    jfif.zeros(2)
                    out.append(jfif.data)
                }
            case 0xE2:
                if keepICC && payload.starts(with: "ICC_PROFILE\u{0}") { keep(segment) }
            case 0xEE:
                if payload.starts(with: "Adobe") { keep(segment) }  // needed to decode CMYK/YCCK correctly
            case 0xE1, 0xE3...0xED, 0xEF, 0xFE:
                break  // EXIF/XMP, other APPn blocks, comments
            case 0xDA:
                keep(segment)
                // Entropy-coded data runs until a marker that isn't a stuffed byte or a restart marker.
                let start = offset
                var index = offset
                while index + 1 < data.count {
                    if data.byte(index) == 0xFF {
                        let next = data.byte(index + 1)
                        if next == 0x00 || (0xD0...0xD7).contains(next) {
                            index += 2
                            continue
                        }
                        if next != 0xFF { break }
                    }
                    index += 1
                }
                if index + 1 >= data.count { index = data.count }
                out.append(data.bytes(start, index - start))
                offset = index
            default:
                keep(segment)
            }
        }
        // Truncated file without an end marker: close it so decoders accept it.
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    /// A minimal EXIF block holding only the orientation tag.
    static func orientationSegment(_ value: Int) -> Data {
        var writer = ByteWriter()
        writer.u16be(0xFFE1)
        writer.u16be(2 + 6 + orientationTIFF(value).count)
        writer.ascii("Exif")
        writer.zeros(2)
        writer.append(orientationTIFF(value))
        return writer.data
    }

    /// Big-endian TIFF structure with one IFD entry: Orientation (0x0112), SHORT.
    static func orientationTIFF(_ value: Int) -> Data {
        var writer = ByteWriter()
        writer.ascii("MM")
        writer.u16be(42)
        writer.u32be(8)
        writer.u16be(1)
        writer.u16be(0x0112)
        writer.u16be(3)
        writer.u32be(1)
        writer.u16be(value)
        writer.u16be(0)
        writer.u32be(0)
        return writer.data
    }
}

enum PNGScrubber {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// Chunks needed to draw the image the same way, including animation (APNG) and HDR colour.
    static let kept: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "cICP", "mDCV", "cLLI",
                                    "sBIT", "bKGD", "pHYs", "hIST", "acTL", "fcTL", "fdAT"]

    static func clean(_ data: Data, orientation: Int?, keepICC: Bool) throws -> Data {
        guard data.count >= 8, data.bytes(0, 8) == signature else { throw MetadataError.corrupt("Not a PNG file.") }
        var out = signature
        var offset = 8
        var pendingOrientation = (orientation ?? 1) != 1 ? orientation : nil
        while offset + 8 <= data.count {
            let length = data.u32be(offset)
            let type = data.fourCC(offset + 4)
            guard data.has(offset, 12 + length) else { throw MetadataError.corrupt("A PNG chunk runs past the end of the file.") }
            let chunkData = data.bytes(offset, 12 + length)
            offset += 12 + length
            if (type == "IDAT" || type == "fdAT" || type == "IEND"), let value = pendingOrientation {
                out.append(chunk("eXIf", JPEGScrubber.orientationTIFF(value)))
                pendingOrientation = nil
            }
            let critical = type.first?.isUppercase ?? false
            if kept.contains(type) || (type == "iCCP" && keepICC) || (critical && !kept.contains(type)) {
                out.append(chunkData)
            }
            if type == "IEND" { break }
        }
        return out
    }

    static func chunk(_ type: String, _ payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32be(payload.count)
        let body = Data(type.utf8) + payload
        writer.append(body)
        writer.u32be(Int(CRC32.checksum(body)))
        return writer.data
    }
}

enum GIFScrubber {
    /// Keeps image blocks, frame timing and the looping extension; drops comments, XMP and other
    /// application extensions.
    static func clean(_ data: Data, keepICC: Bool) throws -> Data {
        guard data.count >= 13, data.starts(with: "GIF8") else { throw MetadataError.corrupt("Not a GIF file.") }
        var offset = 13
        let packed = data.byte(10)
        if packed & 0x80 != 0 { offset += 3 << (Int(packed & 0x07) + 1) }
        guard offset <= data.count else { throw MetadataError.corrupt("The GIF file is truncated.") }
        var out = data.bytes(0, offset)

        func subBlocksEnd(from start: Int) throws -> Int {
            var index = start
            while index < data.count {
                let size = Int(data.byte(index))
                index += 1
                if size == 0 { return index }
                index += size
            }
            throw MetadataError.corrupt("The GIF file is truncated.")
        }

        while offset < data.count {
            let introducer = data.byte(offset)
            switch introducer {
            case 0x21:
                guard data.has(offset, 2) else { throw MetadataError.corrupt("The GIF file is truncated.") }
                let label = data.byte(offset + 1)
                let end = try subBlocksEnd(from: offset + 2)
                var keepBlock = label == 0xF9 || label == 0x01  // graphic control, plain text
                if label == 0xFF, data.has(offset + 2, 12) {
                    let identifier = data.fourCC(offset + 3, length: 11)
                    keepBlock = identifier == "NETSCAPE2.0" || identifier == "ANIMEXTS1.0" || (keepICC && identifier == "ICCRGBG1012")
                }
                if keepBlock { out.append(data.bytes(offset, end - offset)) }
                offset = end
            case 0x2C:
                guard data.has(offset, 11) else { throw MetadataError.corrupt("The GIF file is truncated.") }
                var index = offset + 10
                let localPacked = data.byte(offset + 9)
                if localPacked & 0x80 != 0 { index += 3 << (Int(localPacked & 0x07) + 1) }
                index += 1  // LZW minimum code size
                let end = try subBlocksEnd(from: index)
                out.append(data.bytes(offset, end - offset))
                offset = end
            case 0x3B:
                out.append(0x3B)
                return out
            default:
                throw MetadataError.corrupt("Unexpected GIF block at byte \(offset).")
            }
        }
        out.append(0x3B)
        return out
    }
}

enum WebPScrubber {
    static func clean(_ data: Data, keepICC: Bool) throws -> Data {
        guard data.count >= 12, data.starts(with: "RIFF"), data.fourCC(8) == "WEBP" else { throw MetadataError.corrupt("Not a WebP file.") }
        var chunks = Data()
        var offset = 12
        let end = min(data.count, 8 + data.u32le(4))
        while offset + 8 <= end {
            let type = data.fourCC(offset)
            let size = data.u32le(offset + 4)
            let padded = size + (size & 1)
            guard data.has(offset + 8, size) else { throw MetadataError.corrupt("A WebP chunk runs past the end of the file.") }
            var chunk = data.bytes(offset, min(8 + padded, data.count - offset))
            offset += 8 + padded
            switch type {
            case "EXIF", "XMP ":
                continue
            case "ICCP" where !keepICC:
                continue
            case "VP8X" where chunk.count > 8:
                // Clear the EXIF (0x08) and XMP (0x04) flags, and the ICC flag (0x20) when the profile goes.
                var flags = chunk[chunk.startIndex + 8] & ~UInt8(0x0C)
                if !keepICC { flags &= ~UInt8(0x20) }
                chunk[chunk.startIndex + 8] = flags
            default:
                break
            }
            chunks.append(chunk)
        }
        var writer = ByteWriter()
        writer.ascii("RIFF")
        writer.u32le(4 + chunks.count)
        writer.ascii("WEBP")
        writer.append(chunks)
        return writer.data
    }
}

/// HEIF/HEIC/AVIF keep EXIF and XMP as separate "items" whose bytes live elsewhere in the file. The
/// scrubber overwrites those bytes with zeros and renames the items so readers skip them. The file layout
/// does not change, so the picture, depth and HDR data stay untouched. Orientation and colour live in
/// separate image properties and are kept.
enum HEIFScrubber {
    struct Patch {
        var offset: Int
        var bytes: Data
    }

    struct Item {
        var id: Int
        var typeOffset: Int
        var kind: String
    }

    static func plan(_ data: Data) throws -> [Patch] {
        guard let meta = boxes(in: data, from: 0, to: data.count).first(where: { $0.type == "meta" }) else {
            throw MetadataError.unsupported("This HEIF file has no item list (image sequences aren't supported).")
        }
        let children = boxes(in: data, from: meta.payload + 4, to: meta.end)
        guard let iinf = children.first(where: { $0.type == "iinf" }), let iloc = children.first(where: { $0.type == "iloc" }) else {
            throw MetadataError.unsupported("This HEIF file has an unusual layout.")
        }
        let idatStart = children.first(where: { $0.type == "idat" })?.payload

        // Item infos: find the EXIF and XMP items.
        var targets: [Int: Item] = [:]
        let infVersion = data.byte(iinf.payload)
        let entriesStart = iinf.payload + 4 + (infVersion == 0 ? 2 : 4)
        for infe in boxes(in: data, from: entriesStart, to: iinf.end) where infe.type == "infe" {
            let version = data.byte(infe.payload)
            guard version >= 2 else { continue }
            var cursor = infe.payload + 4
            let id = version == 2 ? data.u16be(cursor) : data.u32be(cursor)
            cursor += (version == 2 ? 2 : 4) + 2
            guard data.has(cursor, 4) else { continue }
            let typeOffset = cursor
            let type = data.fourCC(cursor)
            cursor += 4
            if type == "Exif" {
                targets[id] = Item(id: id, typeOffset: typeOffset, kind: "Exif")
            } else if type == "mime" {
                let nameEnd = data.firstIndex(of: 0, from: cursor, before: infe.end) ?? infe.end
                let contentStart = nameEnd + 1
                let contentEnd = data.firstIndex(of: 0, from: contentStart, before: infe.end) ?? infe.end
                let contentType = contentStart < contentEnd ? data.text(contentStart, contentEnd - contentStart) : ""
                if contentType.contains("rdf+xml") || contentType.contains("xmp") {
                    targets[id] = Item(id: id, typeOffset: typeOffset, kind: "XMP")
                }
            }
        }
        guard !targets.isEmpty else { return [] }

        // Item locations: where each target's bytes are.
        var patches: [Patch] = []
        let version = Int(data.byte(iloc.payload))
        var cursor = iloc.payload + 4
        let offsetSize = Int(data.byte(cursor) >> 4), lengthSize = Int(data.byte(cursor) & 0x0F)
        let baseOffsetSize = Int(data.byte(cursor + 1) >> 4)
        let indexSize = version == 1 || version == 2 ? Int(data.byte(cursor + 1) & 0x0F) : 0
        cursor += 2
        let itemCount = version < 2 ? data.u16be(cursor) : data.u32be(cursor)
        cursor += version < 2 ? 2 : 4
        for _ in 0..<itemCount {
            guard cursor < iloc.end else { throw MetadataError.corrupt("The HEIF item locations are truncated.") }
            let id = version < 2 ? data.u16be(cursor) : data.u32be(cursor)
            cursor += version < 2 ? 2 : 4
            var method = 0
            if version == 1 || version == 2 {
                method = data.u16be(cursor) & 0x0F
                cursor += 2
            }
            cursor += 2  // data reference index
            let baseOffset = data.uintBE(cursor, size: baseOffsetSize)
            cursor += baseOffsetSize
            let extentCount = data.u16be(cursor)
            cursor += 2
            for _ in 0..<extentCount {
                cursor += indexSize
                let extentOffset = data.uintBE(cursor, size: offsetSize)
                cursor += offsetSize
                let extentLength = data.uintBE(cursor, size: lengthSize)
                cursor += lengthSize
                guard targets[id] != nil, extentLength > 0 else { continue }
                let start: Int
                switch method {
                case 0: start = baseOffset + extentOffset
                case 1:
                    guard let idatStart else { continue }
                    start = idatStart + baseOffset + extentOffset
                default: continue
                }
                guard data.has(start, extentLength) else { throw MetadataError.corrupt("A HEIF item points past the end of the file.") }
                patches.append(Patch(offset: start, bytes: Data(count: extentLength)))
            }
        }
        for item in targets.values {
            patches.append(Patch(offset: item.typeOffset, bytes: Data("hide".utf8)))
        }
        return patches
    }

    struct Box {
        var type: String
        var start: Int
        var payload: Int
        var end: Int
    }

    static func boxes(in data: Data, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            var size = data.u32be(offset)
            let type = data.fourCC(offset + 4)
            var header = 8
            if size == 1, data.has(offset + 8, 8) {
                size = data.u64be(offset + 8)
                header = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= header, offset + size <= end else { break }
            result.append(Box(type: type, start: offset, payload: offset + header, end: offset + size))
            offset += size
        }
        return result
    }

    /// Copies `source` to `destination` and blanks the EXIF/XMP items.
    static func clean(_ source: URL, to destination: URL) throws {
        try Patch.apply(try plan(try mappedData(source)), copying: source, to: destination)
    }
}

extension HEIFScrubber.Patch {
    /// Copies `source` to `destination`, then overwrites the given byte ranges in the copy.
    static func apply(_ patches: [HEIFScrubber.Patch], copying source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw MetadataError.writeFailed("Could not copy \(source.lastPathComponent).")
        }
        guard !patches.isEmpty else { return }
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        for patch in patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.bytes)
        }
        try handle.synchronize()
    }
}

/// MPEG-4 and QuickTime files keep tags in `udta` and `meta` boxes (and XMP in a `uuid` box). The
/// scrubber turns those boxes into `free` padding of the same size and zeroes the recording times in
/// the movie, track and media headers. Nothing moves, so the audio and video are untouched.
enum MP4Scrubber {
    static let xmpUUID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])

    static func plan(_ data: Data) throws -> [HEIFScrubber.Patch] {
        var patches: [HEIFScrubber.Patch] = []
        let top = HEIFScrubber.boxes(in: data, from: 0, to: data.count)
        guard top.contains(where: { $0.type == "moov" }) else { throw MetadataError.corrupt("The movie header (moov) is missing.") }

        func neutralize(_ box: HEIFScrubber.Box) {
            patches.append(HEIFScrubber.Patch(offset: box.start + 4, bytes: Data("free".utf8)))
            if box.end > box.payload { patches.append(HEIFScrubber.Patch(offset: box.payload, bytes: Data(count: box.end - box.payload))) }
        }
        func zeroTimes(_ box: HEIFScrubber.Box) {
            guard data.has(box.payload, 4) else { return }
            let width = data.byte(box.payload) == 1 ? 8 : 4
            if data.has(box.payload + 4, width * 2) {
                patches.append(HEIFScrubber.Patch(offset: box.payload + 4, bytes: Data(count: width * 2)))
            }
        }
        func isMetadata(_ box: HEIFScrubber.Box) -> Bool {
            box.type == "udta" || box.type == "meta" || (box.type == "uuid" && data.has(box.payload, 16) && data.bytes(box.payload, 16) == xmpUUID)
        }
        func walk(_ boxes: [HEIFScrubber.Box]) {
            for box in boxes {
                if isMetadata(box) {
                    neutralize(box)
                } else if ["mvhd", "tkhd", "mdhd"].contains(box.type) {
                    zeroTimes(box)
                } else if ["moov", "trak", "mdia"].contains(box.type) {
                    walk(HEIFScrubber.boxes(in: data, from: box.payload, to: box.end))
                }
            }
        }
        walk(top)
        return patches
    }
}
