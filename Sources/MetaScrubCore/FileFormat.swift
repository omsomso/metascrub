import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The container format of a file, decided from its first bytes and, failing that, its type.
enum FileFormat: Equatable, Sendable {
    case jpeg, png, gif, webp, heif, tiff, otherImage
    case mp3, flac, wav, aiff
    case mpeg4, otherMedia
    case pdf
    case office, openDocument
    case unknown

    static func detect(_ url: URL) -> FileFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        let ext = url.pathExtension.lowercased()
        if let format = fromMagic(head, ext: ext, handle: handle) { return format }

        let type = url.typeIdentifier
        if let type, type.conforms(to: .image) || type.conforms(to: .rawImage) {
            return imageIOCanRead(url) ? .otherImage : .unknown
        }
        if let type, type.conforms(to: .audiovisualContent) { return .otherMedia }
        if ext == "mp3" { return .mp3 }
        return imageIOCanRead(url) ? .otherImage : .unknown
    }

    private static func fromMagic(_ head: Data, ext: String, handle: FileHandle) -> FileFormat? {
        if head.count >= 3, head.byte(0) == 0xFF, head.byte(1) == 0xD8, head.byte(2) == 0xFF { return .jpeg }
        if head.count >= 4, head.bytes(0, 4) == Data([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if head.starts(with: "GIF8") { return .gif }
        if head.starts(with: "RIFF"), head.has(8, 4) {
            switch head.fourCC(8) {
            case "WEBP": return .webp
            case "WAVE": return .wav
            default: return nil
            }
        }
        if head.starts(with: "FORM"), head.has(8, 4), ["AIFF", "AIFC"].contains(head.fourCC(8)) { return .aiff }
        if head.starts(with: "fLaC") { return .flac }
        if head.starts(with: "ID3") {
            // FLAC files sometimes carry an ID3 tag in front of the "fLaC" marker.
            if head.count >= 10 {
                let size = ID3.syncsafe(head, 6) + 10
                try? handle.seek(toOffset: UInt64(size))
                if let probe = try? handle.read(upToCount: 4), probe.starts(with: "fLaC") { return .flac }
            }
            return ["m4a", "mp4"].contains(ext) ? nil : .mp3
        }
        if head.starts(with: "%PDF") { return .pdf }
        if head.starts(with: "II*\u{0}") || head.starts(with: "MM\u{0}*") {
            // Many camera raw formats are TIFF inside; only real TIFFs are rewritten.
            return ["tif", "tiff"].contains(ext) ? .tiff : .otherImage
        }
        if head.has(4, 8), head.fourCC(4) == "ftyp" {
            let brand = head.fourCC(8)
            let imageBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1", "avif", "avis", "mif2"]
            if imageBrands.contains(brand) && !["mp4", "mov", "m4v"].contains(ext) { return .heif }
            return .mpeg4
        }
        if head.has(4, 4), ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(head.fourCC(4)), ["mov", "mp4", "m4v", "m4a", "qt"].contains(ext) {
            return .mpeg4
        }
        if head.starts(with: "PK\u{3}\u{4}") {
            switch ext {
            case "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "pptx", "pptm", "potx", "potm", "ppsx", "vsdx":
                return .office
            case "odt", "ods", "odp", "odg", "odf", "ott", "ots", "otp":
                return .openDocument
            default:
                return nil
            }
        }
        if ext == "mp3", head.count >= 2, head.byte(0) == 0xFF, head.byte(1) & 0xE0 == 0xE0 { return .mp3 }
        return nil
    }

    private static func imageIOCanRead(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }
}
