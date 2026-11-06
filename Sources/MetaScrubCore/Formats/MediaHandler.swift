import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// MPEG-4 and QuickTime files (MP4, MOV, M4A, M4V, 3GP) and other formats AVFoundation can read.
/// Cleaning blanks the metadata boxes in place; saving edits uses a pass-through export. Neither re-encodes.
struct MediaHandler: FormatHandler {
    static func fileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov", "qt": return .mov
        case "mp4": return .mp4
        case "m4a", "m4b", "m4r": return .m4a
        case "m4v": return .m4v
        case "3gp": return .mobile3GPP
        case "3g2": return .mobile3GPP2
        default: return nil
        }
    }

    static let keySpaceTitles: [String: (String, String)] = [
        "itsk": ("iTunes Tags", "music.note.list"), "itlk": ("iTunes Extended Tags", "music.note.list"),
        "mdta": ("QuickTime Metadata", "film"), "udta": ("QuickTime User Data", "film.stack"), "uiso": ("ISO User Data", "film.stack"),
        "id3 ": ("ID3 Tag", "music.note.list"), "caaf": ("Core Audio Info", "waveform"), "comn": ("Common", "list.bullet"),
    ]

    static let labels: [String: String] = [
        "itsk/%A9nam": "Title", "itsk/%A9ART": "Artist", "itsk/%A9alb": "Album", "itsk/aART": "Album artist", "itsk/%A9day": "Year",
        "itsk/%A9gen": "Genre", "itsk/gnre": "Genre", "itsk/%A9cmt": "Comment", "itsk/%A9wrt": "Composer", "itsk/cprt": "Copyright",
        "itsk/%A9lyr": "Lyrics", "itsk/%A9too": "Encoder", "itsk/desc": "Description", "itsk/ldes": "Long description",
        "itsk/trkn": "Track", "itsk/disk": "Disc", "itsk/tmpo": "BPM", "itsk/cpil": "Compilation", "itsk/covr": "Artwork",
        "itsk/%A9grp": "Grouping", "itsk/apID": "Account (Apple ID)", "itsk/ownr": "Owner", "itsk/purd": "Purchase date",
        "itsk/cnID": "Catalog ID", "itsk/tvsh": "TV show", "itsk/%A9enc": "Encoded by", "itsk/sonm": "Title sort", "itsk/soar": "Artist sort",
        "itsk/soal": "Album sort", "itsk/stik": "Media kind", "itsk/rtng": "Content rating", "itsk/pgap": "Gapless",
        "mdta/com.apple.quicktime.make": "Device make", "mdta/com.apple.quicktime.model": "Device model",
        "mdta/com.apple.quicktime.software": "Software", "mdta/com.apple.quicktime.creationdate": "Date recorded",
        "mdta/com.apple.quicktime.location.ISO6709": "Location", "mdta/com.apple.quicktime.location.accuracy.horizontal": "Location accuracy",
        "mdta/com.apple.quicktime.title": "Title", "mdta/com.apple.quicktime.artist": "Artist", "mdta/com.apple.quicktime.author": "Author",
        "mdta/com.apple.quicktime.comment": "Comment", "mdta/com.apple.quicktime.description": "Description",
        "mdta/com.apple.quicktime.copyright": "Copyright", "mdta/com.apple.quicktime.keywords": "Keywords",
        "mdta/com.apple.quicktime.content.identifier": "Content identifier", "mdta/com.apple.quicktime.live-photo.auto": "Live Photo auto",
        "udta/%A9xyz": "Location", "udta/%A9mak": "Device make", "udta/%A9mod": "Device model", "udta/%A9swr": "Software",
        "udta/%A9day": "Date", "udta/%A9nam": "Title", "udta/%A9cmt": "Comment", "udta/%A9too": "Encoder",
    ]

    static func templates(for type: AVFileType?) -> [FieldTemplate] {
        if type == .mov {
            return ["title": "Title", "artist": "Artist", "author": "Author", "comment": "Comment", "description": "Description",
                    "copyright": "Copyright", "keywords": "Keywords"]
                .sorted { $0.value < $1.value }
                .map { FieldTemplate("mdta/com.apple.quicktime.\($0.key)", $0.value) }
        }
        return [("%A9nam", "Title"), ("%A9ART", "Artist"), ("%A9alb", "Album"), ("aART", "Album artist"), ("%A9day", "Year"),
                ("%A9gen", "Genre"), ("%A9cmt", "Comment"), ("%A9wrt", "Composer"), ("cprt", "Copyright"), ("%A9lyr", "Lyrics"),
                ("desc", "Description"), ("%A9grp", "Grouping")]
            .map { FieldTemplate("itsk/\($0.0)", $0.1) }
    }

    struct LoadedItem {
        var item: AVMetadataItem
        var key: String
        var identifier: String
        var keySpace: String
        var value: String
        var editable: Bool
        var image: Data?
    }

    static func loadItems(_ asset: AVAsset) async throws -> [LoadedItem] {
        var result: [LoadedItem] = []
        var seen: [String: Int] = [:]
        for format in try await asset.load(.availableMetadataFormats) {
            for item in try await asset.loadMetadata(for: format) {
                let identifier = item.identifier?.rawValue ?? "\(item.keySpace?.rawValue ?? "?")/\(item.key.map { "\($0)" } ?? "?")"
                let keySpace = item.keySpace?.rawValue ?? String(identifier.prefix { $0 != "/" })
                let occurrence = seen[identifier, default: 0]
                seen[identifier] = occurrence + 1
                let key = occurrence > 0 ? "\(identifier)#\(occurrence)" : identifier
                var value = ""
                var image: Data?
                var editable = false
                if let string = try? await item.load(.stringValue) {
                    value = string
                    editable = true
                } else if let date = try? await item.load(.dateValue) {
                    value = Format.date(date)
                } else if let number = try? await item.load(.numberValue) {
                    value = number.stringValue
                    editable = true
                } else if let data = try? await item.load(.dataValue) {
                    if identifier.hasSuffix("/trkn") || identifier.hasSuffix("/disk"), data.count >= 6 {
                        let total = data.u16be(4)
                        value = total > 0 ? "\(data.u16be(2)) of \(total)" : "\(data.u16be(2))"
                    } else if identifier.hasSuffix("covr") || item.commonKey == .commonKeyArtwork {
                        image = data
                        value = "Picture · \(Format.bytes(data.count))"
                    } else {
                        value = "\(Format.bytes(data.count)) of data"
                    }
                }
                result.append(LoadedItem(item: item, key: key, identifier: identifier, keySpace: keySpace, value: value,
                                         editable: editable && ["itsk", "mdta", "udta"].contains(keySpace), image: image))
            }
        }
        return result
    }

    func read(_ url: URL) async throws -> FormatReport {
        let asset = AVURLAsset(url: url)
        let type = Self.fileType(for: url)
        var report = FormatReport(format: (url.typeIdentifier?.localizedDescription ?? "Media file").capitalizedFirst)
        let canWrite = type != nil
        report.canEdit = canWrite
        report.canClean = canWrite
        if !canWrite { report.notes.append("Metadata in this media format is shown read-only. Clean can only remove file-system metadata.") }

        let items = try await Self.loadItems(asset)
        var grouped: [String: [MetadataEntry]] = [:]
        for item in items {
            let label = Self.labels[item.identifier] ?? item.item.commonKey.map { Format.words($0.rawValue) }
                ?? Format.words(String(item.identifier.split(separator: "/").last ?? "").replacingOccurrences(of: "%A9", with: ""))
            let entry = MetadataEntry(key: item.key, label: label, value: item.value, detail: item.identifier.replacingOccurrences(of: "%A9", with: "©"),
                                      editable: canWrite && item.editable, removable: canWrite, image: item.image)
            grouped[item.keySpace, default: []].append(entry)
            if report.location == nil, item.identifier.hasSuffix("ISO6709") || item.identifier == "udta/%A9xyz" {
                report.location = Self.parseISO6709(item.value)
            }
        }
        let primaryKeySpace = type == .mov ? "mdta" : "itsk"
        if canWrite && grouped[primaryKeySpace] == nil && [AVFileType.mov, .mp4, .m4a, .m4v].contains(type) { grouped[primaryKeySpace] = [] }
        for keySpace in grouped.keys.sorted(by: { ($0 == primaryKeySpace ? "" : $0) < ($1 == primaryKeySpace ? "" : $1) }) {
            let (title, symbol) = Self.keySpaceTitles[keySpace] ?? (keySpace.uppercased(), "list.bullet")
            report.sections.append(MetadataSection(id: "av.\(keySpace)", title: title, symbol: symbol, entries: grouped[keySpace]!,
                                                   templates: canWrite && keySpace == primaryKeySpace ? Self.templates(for: type) : []))
        }

        let (facts, tracks) = await Self.trackInfo(asset)
        report.facts = facts
        if !tracks.isEmpty {
            report.sections.append(MetadataSection(id: "av.tracks", title: "Tracks", symbol: "square.stack.3d.down.right", kind: .technical, entries: tracks))
        }
        return report
    }

    static func trackInfo(_ asset: AVAsset) async -> ([Fact], [MetadataEntry]) {
        var facts: [Fact] = []
        var entries: [MetadataEntry] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            facts.append(Fact("Duration", Format.duration(duration.seconds), symbol: "clock"))
        }
        let tracks = (try? await asset.load(.tracks)) ?? []
        for (index, track) in tracks.enumerated() {
            var parts: [String] = []
            let description = try? await track.load(.formatDescriptions).first
            if let description {
                let code = CMFormatDescriptionGetMediaSubType(description)
                let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces) ?? "?"
                parts.append(codecName(fourCC))
            }
            switch track.mediaType {
            case .video:
                if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let shown = size.applying(transform)
                    let text = "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"
                    parts.append(text)
                    if !facts.contains(where: { $0.label == "Video" }) {
                        let rate = (try? await track.load(.nominalFrameRate)) ?? 0
                        facts.append(Fact("Video", [parts.first ?? "", text, rate > 0 ? String(format: "%.3g fps", rate) : ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "), symbol: "film"))
                    }
                }
            case .audio:
                if let description, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    parts.append(Format.hertz(stream.mSampleRate))
                    parts.append(Format.channels(Int(stream.mChannelsPerFrame)))
                    if !facts.contains(where: { $0.label == "Audio" }) {
                        facts.append(Fact("Audio", parts.joined(separator: " · "), symbol: "waveform"))
                    }
                }
            default:
                break
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { parts.append("\(Int((rate / 1000).rounded())) kbps") }
            let kind = Format.words(track.mediaType.rawValue == "soun" ? "audio" : track.mediaType.rawValue == "vide" ? "video" : track.mediaType.rawValue)
            entries.append(MetadataEntry(key: "track\(index)", label: "\(kind) track", value: parts.joined(separator: " · "), classify: false))
        }
        return (facts, entries)
    }

    static func codecName(_ fourCC: String) -> String {
        let names = ["avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "mp4a": "AAC", "usac": "xHE-AAC", "aach": "HE-AAC", "aacp": "HE-AAC v2",
                     "aac": "AAC", "alac": "Apple Lossless", "ac-3": "Dolby Digital", "ec-3": "Dolby Digital Plus", "lpcm": "PCM",
                     "apcn": "ProRes 422", "apch": "ProRes 422 HQ", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
                     "ap4h": "ProRes 4444", "jpeg": "Motion JPEG", "mp4v": "MPEG-4 Video", "tx3g": "Subtitles", "text": "Text",
                     "tmcd": "Timecode", "mebx": "Metadata", "Opus": "Opus", "fLaC": "FLAC", ".mp3": "MP3"]
        return names[fourCC] ?? fourCC
    }

    /// "+46.2044+006.1432+375.000/" → coordinates.
    static func parseISO6709(_ text: String) -> GeoPoint? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if (character == "+" || character == "-" || character == "/") && !current.isEmpty {
                if let value = Double(current) { numbers.append(value) }
                current = ""
            }
            if character != "/" { current.append(character) }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2 else { return nil }
        let point = GeoPoint(latitude: numbers[0], longitude: numbers[1], altitude: numbers.count > 2 ? numbers[2] : nil)
        return point.isValid ? point : nil
    }

    // MARK: Writing

    /// Pass-through export with `metadata` replacing the file's own (must not be empty).
    private func export(_ asset: AVAsset, metadata: [AVMetadataItem], to destination: URL, type: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MetadataError.writeFailed("AVFoundation can't rewrite this file.")
        }
        session.metadata = metadata
        // Export into a file with the canonical extension, then move it to the requested name.
        let folder = destination.deletingLastPathComponent()
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? destination.pathExtension
        let temporary = folder.appendingPathComponent("export-\(UUID().uuidString).\(ext)")
        do {
            try await session.export(to: temporary, as: type)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw MetadataError.writeFailed("macOS couldn't rewrite this file to save the edits (\(error.localizedDescription)). Some codecs, such as xHE-AAC, can't be copied this way. Cleaning still works.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        guard Self.fileType(for: source) != nil else { throw MetadataError.unsupported("Cleaning isn't supported for this media format.") }
        try HEIFScrubber.Patch.apply(try MP4Scrubber.plan(try mappedData(source)), copying: source, to: destination)
        return []
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        guard let type = Self.fileType(for: source) else { throw MetadataError.unsupported("Editing isn't supported for this media format.") }
        let asset = AVURLAsset(url: source)
        let loaded = try await Self.loadItems(asset)
        var items: [AVMetadataItem] = []
        var pending = Dictionary(edits.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        for entry in loaded {
            guard let edit = pending.removeValue(forKey: entry.key) else {
                items.append(entry.item)
                continue
            }
            guard case .set(let value) = edit.action else { continue }
            guard let copy = entry.item.mutableCopy() as? AVMutableMetadataItem else { continue }
            if (try? await entry.item.load(.numberValue)) != nil, let number = Double(value) {
                copy.value = NSNumber(value: number)
            } else {
                copy.value = value as NSString
            }
            items.append(copy)
        }
        for edit in pending.values {
            guard case .set(let value) = edit.action else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: edit.key)
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        // An empty list would make AVFoundation copy the original metadata, so "everything removed" is a clean.
        if items.isEmpty { return try await clean(source, to: destination, options: CleanOptions()) }
        try await export(asset, metadata: items, to: destination, type: type)

        // Report fields the container couldn't hold.
        let written = Set(try await Self.loadItems(AVURLAsset(url: destination)).map(\.identifier))
        let wanted = edits.compactMap { $0.newValue == nil ? nil : $0.key.split(separator: "#").first.map(String.init) }
        let dropped = wanted.filter { !written.contains($0) }
        return dropped.isEmpty ? [] : ["These fields couldn't be stored in this file type: \(dropped.map { Self.labels[$0] ?? $0 }.joined(separator: ", "))."]
    }
}
