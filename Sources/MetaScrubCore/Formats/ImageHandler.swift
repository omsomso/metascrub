import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images through ImageIO: EXIF, TIFF, GPS, IPTC and XMP are read as one XMP-style tree of tags,
/// which is also what edits are written back as.
struct ImageHandler: FormatHandler {
    let format: FileFormat

    /// Formats whose metadata ImageIO rewrites without re-compressing the picture.
    private var copiesLosslessly: Bool { format == .jpeg || format == .heif }
    /// Formats where re-encoding the pixels loses nothing, so edits may go through a full rewrite.
    private var reencodesLosslessly: Bool { format == .png || format == .tiff }

    func read(_ url: URL) async throws -> FormatReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw MetadataError.unreadable("ImageIO can't open this image.")
        }
        let frames = CGImageSourceGetCount(source)
        let typeID = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let name = typeID.flatMap { UTType($0)?.localizedDescription } ?? "Image"
        var report = FormatReport(format: name.capitalizedFirst)
        report.facts = Self.facts(properties, frames: frames)
        report.location = Self.location(properties)

        let editable = frames == 1 && (copiesLosslessly || reencodesLosslessly)
        // PNG text chunks are read directly: ImageIO hides custom keywords such as AI workflows.
        var chunks: [PNGText.Chunk] = []
        if format == .png { chunks = PNGText.read(try mappedData(url)).filter { !$0.isXMP } }
        let tags = Self.tagSections(source, editable: editable, hiding: Set(chunks.map(\.text)))
        let (generationChunks, otherChunks) = Self.pngTextEntries(chunks, editable: editable)
        let generation = generationChunks + tags.generation
        let sources = chunks.filter { GenerationInfo.label(forKeyword: $0.keyword) != nil }.map(\.text) + tags.generationTexts
        let summary = GenerationInfo.summary(sources).map { label, value in
            MetadataEntry(key: "gen:\(label)", label: label, value: value, multiline: value.count > 80 || label.hasSuffix("prompt"),
                          classify: false)
        }
        report.sections = [
            MetadataSection(id: "img.generation.summary", title: "Generation Details", symbol: "sparkles", kind: .derived, entries: summary,
                            note: "Read from the AI generator's data in this file. Clean removes it together with that data."),
            MetadataSection(id: "img.generation", title: "AI Generation Data", symbol: "sparkles.rectangle.stack", entries: generation,
                            note: generation.isEmpty ? nil : "Saved by the image generator: the prompt, settings and node graph. Large fields are read-only; use Copy Value to take the JSON."),
        ]
        if format == .png {
            report.sections.append(MetadataSection(
                id: "img.pngtext", title: "PNG Text", symbol: "text.alignleft", entries: otherChunks,
                templates: editable ? ["Title", "Author", "Description", "Copyright", "Comment", "Software", "Source"].map { FieldTemplate("png:\($0)", $0) } : [],
                customFieldHint: editable ? "Text name, e.g. Comment" : nil))
        }
        report.sections += tags.sections
        report.sections += Self.extraSections(properties)
        report.canEdit = editable
        report.canClean = [.jpeg, .png, .gif, .webp, .heif, .tiff].contains(format)
        if format == .tiff { report.notes.append("Cleaning and saving rewrite the TIFF image data without loss.") }
        if format == .otherImage { report.notes.append("Metadata in this image format is shown read-only. Clean can only remove file-system metadata.") }
        if format == .webp || format == .gif { report.notes.append("macOS can't write this image format, so its metadata is read-only; Clean still removes it without loss.") }
        return report
    }

    // MARK: Reading

    static func facts(_ properties: [String: Any], frames: Int) -> [Fact] {
        var facts: [Fact] = []
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            let megapixels = Double(width * height) / 1_000_000
            let suffix = megapixels >= 1 ? String(format: " · %.1f MP", megapixels) : ""
            facts.append(Fact("Dimensions", "\(width) × \(height)\(suffix)", symbol: "aspectratio"))
        }
        var color: [String] = []
        if let model = properties[kCGImagePropertyColorModel as String] as? String { color.append(model) }
        if let depth = properties[kCGImagePropertyDepth as String] as? Int { color.append("\(depth)-bit") }
        if let profile = properties[kCGImagePropertyProfileName as String] as? String { color.append(profile) }
        if !color.isEmpty { facts.append(Fact("Color", color.joined(separator: " · "), symbol: "paintpalette")) }
        if let dpi = properties[kCGImagePropertyDPIWidth as String] as? Double, dpi > 0 {
            facts.append(Fact("Resolution", "\(Int(dpi.rounded())) dpi", symbol: "ruler"))
        }
        if frames > 1 { facts.append(Fact("Frames", "\(frames)", symbol: "square.stack")) }
        return facts
    }

    static func location(_ properties: [String: Any]) -> GeoPoint? {
        guard let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              var longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W" { longitude = -longitude }
        var altitude = (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue
        if let value = altitude, (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue == 1 { altitude = -value }
        let point = GeoPoint(latitude: latitude, longitude: longitude, altitude: altitude)
        return point.isValid ? point : nil
    }

    struct Group {
        var id: String
        var title: String
        var symbol: String
    }

    static let groups: [Group] = [
        Group(id: "img.camera", title: "Camera", symbol: "camera"),
        Group(id: "img.capture", title: "Capture Settings", symbol: "camera.aperture"),
        Group(id: "img.location", title: "Location", symbol: "location"),
        Group(id: "img.description", title: "Description & Rights", symbol: "text.quote"),
        Group(id: "img.image", title: "Image", symbol: "photo"),
        Group(id: "img.xmp", title: "XMP & Editing History", symbol: "curlybraces"),
    ]

    /// How the pixels are stored. Not personal, so these don't count as metadata to clean.
    static let technicalTags: Set<String> = [
        "tiff:Orientation", "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit", "tiff:PhotometricInterpretation",
        "tiff:Compression", "tiff:TileWidth", "tiff:TileLength", "tiff:BitsPerSample", "tiff:SamplesPerPixel",
        "tiff:PlanarConfiguration", "tiff:YCbCrPositioning", "tiff:YCbCrSubSampling", "tiff:ImageWidth", "tiff:ImageLength",
        "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace", "exif:ComponentsConfiguration", "exif:ExifVersion",
        "exif:FlashpixVersion", "exif:FlashPixVersion", "exif:SceneCaptureType", "exif:SensingMethod",
    ]

    static func groupID(prefix: String, name: String) -> String {
        if technicalTags.contains("\(prefix):\(name)") { return "img.image" }
        switch prefix {
        case "exif" where name.hasPrefix("GPS"):
            return "img.location"
        case "tiff":
            if ["Make", "Model", "Software", "HostComputer"].contains(name) { return "img.camera" }
            if ["Artist", "Copyright", "ImageDescription"].contains(name) { return "img.description" }
            return "img.capture"
        case "aux":
            return "img.camera"
        case "exifEX":
            return ["LensMake", "LensModel", "LensSerialNumber", "BodySerialNumber", "CameraOwnerName", "LensSpecification"].contains(name)
                ? "img.camera" : "img.capture"
        case "exif":
            return "img.capture"
        case "dc", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt", "xmpRights", "plus":
            return "img.description"
        default:
            return "img.xmp"
        }
    }

    static let labels: [String: String] = [
        "tiff:Make": "Camera make", "tiff:Model": "Camera model", "tiff:Software": "Software", "tiff:HostComputer": "Host computer",
        "tiff:Artist": "Artist", "tiff:Copyright": "Copyright", "tiff:ImageDescription": "Image description",
        "tiff:Orientation": "Orientation", "tiff:DateTime": "Date modified", "tiff:XResolution": "Horizontal resolution",
        "tiff:YResolution": "Vertical resolution", "tiff:ResolutionUnit": "Resolution unit",
        "exif:DateTimeOriginal": "Date taken", "exif:DateTimeDigitized": "Date digitized", "exif:ExposureTime": "Exposure time",
        "exif:FNumber": "Aperture (f-number)", "exif:ISOSpeedRatings": "ISO", "exif:FocalLength": "Focal length",
        "exif:FocalLenIn35mmFilm": "Focal length (35 mm)", "exif:Flash": "Flash", "exif:ExposureProgram": "Exposure program",
        "exif:MeteringMode": "Metering mode", "exif:WhiteBalance": "White balance", "exif:ExposureBiasValue": "Exposure bias",
        "exif:UserComment": "User comment", "exif:LensModel": "Lens", "exifEX:LensModel": "Lens model", "exifEX:LensMake": "Lens make",
        "exifEX:BodySerialNumber": "Camera serial number", "exifEX:LensSerialNumber": "Lens serial number",
        "exifEX:CameraOwnerName": "Camera owner", "exifEX:LensSpecification": "Lens specification",
        "exif:GPSLatitude": "Latitude", "exif:GPSLongitude": "Longitude", "exif:GPSAltitude": "Altitude",
        "exif:GPSAltitudeRef": "Altitude reference", "exif:GPSTimeStamp": "GPS time", "exif:GPSDateStamp": "GPS date",
        "exif:GPSSpeed": "Speed", "exif:GPSImgDirection": "Direction", "exif:GPSHPositioningError": "Position accuracy",
        "exif:PixelXDimension": "Width", "exif:PixelYDimension": "Height", "exif:ColorSpace": "Color space",
        "dc:title": "Title", "dc:description": "Description", "dc:creator": "Creator", "dc:rights": "Rights", "dc:subject": "Keywords",
        "xmp:CreatorTool": "Creator tool", "xmp:CreateDate": "Created", "xmp:ModifyDate": "Modified", "xmp:MetadataDate": "Metadata date",
        "xmp:Rating": "Rating", "xmpMM:DocumentID": "Document ID", "xmpMM:InstanceID": "Instance ID",
        "xmpMM:OriginalDocumentID": "Original document ID", "xmpMM:History": "Edit history", "xmpMM:DerivedFrom": "Derived from",
        "photoshop:DateCreated": "Date created", "photoshop:City": "City", "photoshop:Country": "Country",
        "photoshop:State": "State / province", "photoshop:Credit": "Credit", "photoshop:Source": "Source",
        "photoshop:Headline": "Headline", "photoshop:AuthorsPosition": "Creator's job title",
        "Iptc4xmpCore:Location": "Sublocation", "Iptc4xmpCore:CountryCode": "Country code", "aux:SerialNumber": "Camera serial number",
        "aux:Lens": "Lens", "aux:LensSerialNumber": "Lens serial number", "aux:OwnerName": "Camera owner",
    ]

    static let templates: [String: [FieldTemplate]] = [
        "img.description": [
            FieldTemplate("dc:title", "Title"), FieldTemplate("dc:description", "Description"), FieldTemplate("dc:creator", "Creator"),
            FieldTemplate("dc:rights", "Rights"), FieldTemplate("dc:subject", "Keywords (separate with ;)"),
            FieldTemplate("photoshop:Credit", "Credit"), FieldTemplate("photoshop:City", "City"), FieldTemplate("photoshop:Country", "Country"),
        ],
        "img.camera": [
            FieldTemplate("tiff:Make", "Camera make"), FieldTemplate("tiff:Model", "Camera model"), FieldTemplate("tiff:Software", "Software"),
        ],
        "img.capture": [
            FieldTemplate("exif:DateTimeOriginal", "Date taken"), FieldTemplate("exif:UserComment", "User comment"),
        ],
        "img.xmp": [
            FieldTemplate("xmp:Rating", "Rating"), FieldTemplate("xmp:CreatorTool", "Creator tool"),
        ],
    ]

    /// Tags ImageIO fills in from standard PNG text chunks, with the chunk keyword. The tag is hidden when the
    /// chunk is shown, and editing the tag edits the chunk too (ImageIO prefers the chunk when reading).
    static let pngMirrorKeywords: [String: String] = [
        "dc:title": "Title", "dc:description": "Description", "tiff:ImageDescription": "Description", "dc:creator": "Author",
        "tiff:Artist": "Author", "dc:rights": "Copyright", "tiff:Copyright": "Copyright", "exif:UserComment": "Comment",
        "tiff:Software": "Software", "xmp:CreatorTool": "Software",
    ]
    static var pngMirrors: Set<String> { Set(pngMirrorKeywords.keys) }

    struct TagSections {
        var sections: [MetadataSection]
        /// Generator data some tools keep in EXIF fields (ComfyUI WebP, Automatic1111 JPEG).
        var generation: [MetadataEntry]
        var generationTexts: [String]
    }

    static func tagSections(_ source: CGImageSource, editable: Bool, hiding hidden: Set<String> = []) -> TagSections {
        var entriesByGroup: [String: [MetadataEntry]] = [:]
        var generation: [MetadataEntry] = []
        var generationTexts: [String] = []
        if let tree = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(tree, nil, nil) { path, tag in
                let key = path as String
                let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? String(key.split(separator: ":").first ?? "")
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? key
                guard prefix != "iio" else { return true }  // ImageIO bookkeeping, not stored in the file
                let (value, simple) = render(tag)
                if pngMirrors.contains(key) && hidden.contains(value) { return true }
                if let generationLabel = GenerationInfo.label(forFieldText: value) {
                    generation.append(MetadataEntry(key: key, label: generationLabel, value: displayText(value), detail: key,
                                                    editable: editable && simple && isEditableText(value), removable: editable,
                                                    multiline: true, highlight: .generation))
                    generationTexts.append(value)
                    return true
                }
                let group = groupID(prefix: prefix, name: name)
                let label = labels[key] ?? Format.words(name)
                let entry = MetadataEntry(key: key, label: label, value: value, detail: key, editable: editable && simple,
                                          removable: editable, highlight: group == "img.location" ? .location : nil)
                entriesByGroup[group, default: []].append(entry)
                return true
            }
        }
        let sections = groups.map { group in
            let entries = (entriesByGroup[group.id] ?? []).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return MetadataSection(id: group.id, title: group.title, symbol: group.symbol,
                                   kind: group.id == "img.image" ? .technical : .embedded, entries: entries,
                                   templates: editable ? (templates[group.id] ?? []) : [],
                                   customFieldHint: editable && group.id == "img.xmp" ? "prefix:Name, e.g. xmp:Label" : nil)
        }
        return TagSections(sections: sections, generation: generation, generationTexts: generationTexts)
    }

    /// Longer values (whole workflows) are shown, copied and removed, but not edited in place.
    static let editableLimit = 4000

    /// Node graphs and other JSON are easy to break as free text, so they're read-only (still removable).
    static func isEditableText(_ text: String) -> Bool {
        guard text.count <= editableLimit else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.drop { $0 != "{" && $0 != "[" }
        return body.isEmpty || (try? JSONSerialization.jsonObject(with: Data(body.utf8))) == nil
    }

    /// Large JSON is shown indented so it can be read; everything else as stored.
    static func displayText(_ text: String) -> String {
        guard text.count > 200, let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
        let prefix = text[..<start]
        guard prefix.count <= 10, let object = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return text
        }
        return String(prefix) + String(decoding: pretty, as: UTF8.self)
    }

    /// PNG text chunks as entries, split into generator data and ordinary text.
    static func pngTextEntries(_ chunks: [PNGText.Chunk], editable: Bool) -> ([MetadataEntry], [MetadataEntry]) {
        var generation: [MetadataEntry] = []
        var other: [MetadataEntry] = []
        for (chunk, key) in zip(chunks, PNGText.keys(chunks)) {
            let size = chunk.text.utf8.count
            let generationLabel = GenerationInfo.label(forKeyword: chunk.keyword)
            let detail = "\(chunk.keyword) · \(chunk.type)" + (size > 1024 ? " · \(Format.bytes(size))" : "")
            let entry = MetadataEntry(key: key, label: generationLabel ?? chunk.keyword, value: displayText(chunk.text), detail: detail,
                                      editable: editable && isEditableText(chunk.text), removable: editable,
                                      highlight: generationLabel == nil ? nil : .generation, classify: generationLabel == nil)
            if generationLabel != nil { generation.append(entry) } else { other.append(entry) }
        }
        return (generation, other)
    }

    /// Renders a tag value; `simple` is false for structures, which are shown read-only.
    static func render(_ tag: CGImageMetadataTag) -> (String, Bool) {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return ("", true) }
        switch CGImageMetadataTagGetType(tag) {
        case .arrayOrdered, .arrayUnordered, .alternateArray:
            let parts = (value as? [Any] ?? []).map { describe($0) }
            return (parts.joined(separator: "; "), parts.allSatisfy { !$0.contains("\n") })
        case .alternateText:
            let parts = (value as? [Any] ?? []).map { describe($0) }
            return (parts.first ?? "", true)
        case .structure:
            return (describe(value), false)
        default:
            return (describe(value), true)
        }
    }

    static func describe(_ value: Any) -> String {
        let object = value as CFTypeRef
        if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
            return render(object as! CGImageMetadataTag).0
        }
        switch value {
        case let string as String: return string
        case let array as [Any]: return array.map(describe).joined(separator: "; ")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { "\($0.split(separator: ":").last ?? Substring($0)): \(describe(dictionary[$0]!))" }
                .joined(separator: "\n")
        default: return "\(value)"
        }
    }

    /// Property dictionaries not covered by the tag tree: maker notes, PNG text, Photoshop resources, DNG.
    static func extraSections(_ properties: [String: Any]) -> [MetadataSection] {
        let inTree: Set<String> = ["{Exif}", "{TIFF}", "{GPS}", "{IPTC}", "{ExifAux}"]
        let technical: Set<String> = ["{JFIF}", "{GIF}", "{HEIF}", "{HEICS}", "{Raw}", "{AVIS}", "{WebP}", "{TGA}", "{OpenEXR}", "{PNG}"]
        // PNG text is read from the chunks themselves (see pngTextEntries).
        let pngText: Set<String> = ["Author", "Comment", "Copyright", "CreationTime", "Description", "Disclaimer", "Software", "Source",
                                    "Title", "Warning", "ModificationTime"]
        var sections: [MetadataSection] = []
        for name in properties.keys.sorted() where name.hasPrefix("{") && !inTree.contains(name) {
            guard let dictionary = properties[name] as? [String: Any], !dictionary.isEmpty else { continue }
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if name == "{PNG}" {
                let rest = dictionary.filter { !pngText.contains($0.key) }
                if !rest.isEmpty {
                    sections.append(MetadataSection(id: "img.png", title: "PNG", symbol: "photo", kind: .technical, entries: entries(rest, prefix: "pngprop")))
                }
                continue
            }
            let isMaker = clean.hasPrefix("Maker")
            let title = isMaker ? "Maker Notes (\(clean.dropFirst(5)))" : clean
            sections.append(MetadataSection(id: "img.\(clean.lowercased())", title: title, symbol: isMaker ? "camera.badge.ellipsis" : "list.bullet",
                                            kind: technical.contains(name) ? .technical : .embedded,
                                            entries: entries(dictionary, prefix: clean.lowercased()),
                                            note: isMaker ? "Private data written by the camera maker, often including serial numbers. Read-only; Clean removes it." : nil))
        }
        return sections
    }

    private static func entries(_ dictionary: [String: Any], prefix: String) -> [MetadataEntry] {
        dictionary.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let value = FileSystemMetadata.describe(dictionary[key]!)
            let label = Int(key) != nil ? "Tag \(key)" : Format.words(key)
            return MetadataEntry(key: "\(prefix):\(key)", label: label, value: value, detail: nil, multiline: value.count > 80)
        }
    }

    // MARK: Editing

    static let namespaces: [String: String] = [
        "dc": "http://purl.org/dc/elements/1.1/",
        "xmp": "http://ns.adobe.com/xap/1.0/",
        "xmpRights": "http://ns.adobe.com/xap/1.0/rights/",
        "xmpMM": "http://ns.adobe.com/xap/1.0/mm/",
        "photoshop": "http://ns.adobe.com/photoshop/1.0/",
        "tiff": "http://ns.adobe.com/tiff/1.0/",
        "exif": "http://ns.adobe.com/exif/1.0/",
        "exifEX": "http://cipa.jp/exif/1.0/",
        "aux": "http://ns.adobe.com/exif/1.0/aux/",
        "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
        "Iptc4xmpExt": "http://iptc.org/std/Iptc4xmpExt/2008-02-29/",
    ]

    static let arrayKinds: [String: CGImageMetadataType] = [
        "dc:subject": .arrayUnordered, "dc:creator": .arrayOrdered, "dc:contributor": .arrayUnordered, "dc:publisher": .arrayUnordered,
        "dc:type": .arrayUnordered, "dc:language": .arrayUnordered, "dc:date": .arrayOrdered,
        "photoshop:SupplementalCategories": .arrayUnordered, "xmp:Identifier": .arrayUnordered,
    ]

    /// The same value is often stored twice (EXIF and XMP). Edits keep the copies in step.
    static let mirrors: [[String]] = [
        ["exif:DateTimeOriginal", "photoshop:DateCreated", "photoshop:DateTimeOriginal"],
        ["exif:DateTimeDigitized", "xmp:CreateDate"],
        ["tiff:DateTime", "xmp:ModifyDate"],
        ["tiff:Artist", "dc:creator"],
        ["tiff:Copyright", "dc:rights"],
        ["tiff:ImageDescription", "dc:description"],
        ["tiff:Software", "xmp:CreatorTool"],
    ]

    static func editedTree(_ source: CGImageSource, _ edits: [MetadataEdit]) throws -> CGMutableImageMetadata {
        let tree = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        for edit in edits {
            let group = mirrors.first { $0.contains(edit.key) } ?? [edit.key]
            switch edit.action {
            case .remove:
                for path in group { CGImageMetadataRemoveTagWithPath(tree, nil, path as CFString) }
            case .set(let value):
                try set(edit.key, value, in: tree)
                // Update the mirrored copies that exist, so the old value doesn't win back.
                for path in group where path != edit.key && CGImageMetadataCopyTagWithPath(tree, nil, path as CFString) != nil {
                    try? set(path, value, in: tree)
                }
            }
        }
        return tree
    }

    static func set(_ path: String, _ value: String, in tree: CGMutableImageMetadata) throws {
        let parts = path.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw MetadataError.unsupported("“\(path)” isn't a valid field name. Use prefix:Name, e.g. xmp:Label.")
        }
        let (prefix, name) = (parts[0], parts[1])
        let existing = CGImageMetadataCopyTagWithPath(tree, nil, path as CFString)
        let namespace = existing.flatMap { CGImageMetadataTagCopyNamespace($0) as String? } ?? namespaces[prefix]
        guard let namespace else {
            throw MetadataError.unsupported("Unknown prefix “\(prefix)”. Use one of: \(namespaces.keys.sorted().joined(separator: ", ")).")
        }
        if existing == nil && namespaces[prefix] != nil {
            CGImageMetadataRegisterNamespaceForPrefix(tree, namespace as CFString, prefix as CFString, nil)
        }
        let kind = existing.map(CGImageMetadataTagGetType) ?? arrayKinds[path] ?? .string
        if kind == .arrayOrdered || kind == .arrayUnordered {
            let items = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let tag = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString, kind, items as CFArray),
                  CGImageMetadataSetTagWithPath(tree, nil, path as CFString, tag) else {
                throw MetadataError.writeFailed("Could not set \(path).")
            }
        } else if !CGImageMetadataSetValueWithPath(tree, nil, path as CFString, value as CFString) {
            guard let tag = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString, .string, value as CFString),
                  CGImageMetadataSetTagWithPath(tree, nil, path as CFString, tag) else {
                throw MetadataError.writeFailed("Could not set \(path).")
            }
        }
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(imageSource) else {
            throw MetadataError.unreadable("ImageIO can't open this image.")
        }
        var textEdits = edits.filter { $0.key.hasPrefix("png:") }
        let tagEdits = edits.filter { !$0.key.hasPrefix("png:") }
        let readOnly: Set<String> = ["img.generation.summary", "img.png"]
        let unsupported = tagEdits.filter { !$0.sectionID.hasPrefix("img.") || $0.sectionID.hasPrefix("img.maker") || readOnly.contains($0.sectionID) }
        guard unsupported.isEmpty, format == .png || textEdits.isEmpty else { throw MetadataError.unsupported("Some of these fields are read-only.") }

        let original = format == .png ? try mappedData(source) : Data()
        let chunks = PNGText.read(original).filter { !$0.isXMP }
        for edit in tagEdits {
            guard let keyword = Self.pngMirrorKeywords[edit.key], chunks.contains(where: { $0.keyword == keyword }),
                  !textEdits.contains(where: { $0.key == "png:\(keyword)" }) else { continue }
            textEdits.append(MetadataEdit(sectionID: "img.pngtext", key: "png:\(keyword)", action: edit.action))
        }
        var notes: [String] = []
        if !tagEdits.isEmpty {
            let tree = try Self.editedTree(imageSource, tagEdits)
            // Don't let ImageIO write a second copy of values the PNG text chunks already hold.
            let texts = Set(chunks.map(\.text))
            for path in Self.pngMirrors where !tagEdits.contains(where: { $0.key == path }) {
                if let value = CGImageMetadataCopyStringValueWithPath(tree, nil, path as CFString) as String?, texts.contains(value) {
                    CGImageMetadataRemoveTagWithPath(tree, nil, path as CFString)
                }
            }
            notes += try write(tree, from: imageSource, type: type, to: destination, checking: tagEdits)
        }
        if format == .png {
            // ImageIO drops text chunks it doesn't know; put every one back (with the text edits applied).
            let edited = try PNGText.applying(textEdits, to: chunks)
            let base = tagEdits.isEmpty ? original : try Data(contentsOf: destination)
            try PNGText.replacingText(in: base, with: edited).write(to: destination)
        }
        return notes
    }

    private func write(_ tree: CGMutableImageMetadata, from imageSource: CGImageSource, type: CFString, to destination: URL,
                       checking edits: [MetadataEdit]) throws -> [String] {
        var notes: [String] = []
        if copiesLosslessly {
            guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
                throw MetadataError.writeFailed("Could not create the edited image.")
            }
            let options = [kCGImageDestinationMetadata: tree, kCGImageDestinationMergeMetadata: false] as CFDictionary
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destinationRef, imageSource, options, &error) else {
                throw MetadataError.writeFailed("ImageIO couldn't write the metadata: \(error?.takeRetainedValue().localizedDescription ?? "unknown error").")
            }
        } else {
            try Self.rewrite(imageSource, type: type, metadata: tree, to: destination)
        }
        let missed = Self.unapplied(edits, in: destination)
        if !missed.isEmpty {
            if format == .heif {
                // ImageIO keeps some HEIF fields when copying; fall back to a full rewrite.
                try? FileManager.default.removeItem(at: destination)
                try Self.rewrite(imageSource, type: type, metadata: tree, to: destination, quality: 0.95)
                notes.append("To change these fields the image was re-compressed at high quality.")
                let stillMissed = Self.unapplied(edits, in: destination)
                if !stillMissed.isEmpty { notes.append("These fields could not be changed in this format: \(stillMissed.joined(separator: ", ")).") }
            } else {
                notes.append("These fields could not be changed in this format: \(missed.joined(separator: ", ")).")
            }
        }
        return notes
    }

    static func rewrite(_ source: CGImageSource, type: CFString, metadata: CGImageMetadata, to destination: URL, quality: Double = 1.0) throws {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw MetadataError.writeFailed("Could not create the edited image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation = properties[kCGImagePropertyOrientation as String] { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImageAndMetadata(destinationRef, image, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw MetadataError.writeFailed("Could not write the edited image.") }
    }

    /// Paths whose removal did not take effect.
    static func unapplied(_ edits: [MetadataEdit], in url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return edits.map(\.key) }
        let tree = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        return edits.compactMap { edit in
            let tag = tree.flatMap { CGImageMetadataCopyTagWithPath($0, nil, edit.key as CFString) }
            switch edit.action {
            case .remove: return tag == nil ? nil : edit.key
            case .set: return tag == nil ? edit.key : nil
            }
        }
    }

    // MARK: Cleaning

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        let orientation = options.keepOrientation ? Self.orientation(of: source) : nil
        switch format {
        case .jpeg:
            try JPEGScrubber.clean(try mappedData(source), orientation: orientation, keepICC: options.keepColorProfile).write(to: destination)
        case .png:
            try PNGScrubber.clean(try mappedData(source), orientation: orientation, keepICC: options.keepColorProfile).write(to: destination)
        case .gif:
            try GIFScrubber.clean(try mappedData(source), keepICC: options.keepColorProfile).write(to: destination)
        case .webp:
            try WebPScrubber.clean(try mappedData(source), keepICC: options.keepColorProfile).write(to: destination)
            return orientation.map { $0 != 1 ? ["The orientation flag was removed with the EXIF data; the photo may show rotated."] : [] } ?? []
        case .heif:
            try HEIFScrubber.clean(source, to: destination)
            if Self.hasPersonalMetadata(destination) {
                try? FileManager.default.removeItem(at: destination)
                try Self.reencodeBare(source, to: destination, orientation: orientation)
                return ["This HEIF file had metadata in an unusual place, so the image was re-compressed at high quality."]
            }
        case .tiff:
            try Self.reencodeBare(source, to: destination, orientation: orientation)
        default:
            throw MetadataError.unsupported("Cleaning isn't supported for this image format.")
        }
        return []
    }

    static func orientation(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
    }

    static func hasPersonalMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        if properties["{GPS}"] != nil || properties["{IPTC}"] != nil { return true }
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        return tiff["Make"] != nil || tiff["Model"] != nil || tiff["Artist"] != nil || exif["DateTimeOriginal"] != nil
    }

    /// Re-saves every frame with no metadata except orientation. Used for TIFF, where this is lossless.
    static func reencodeBare(_ url: URL, to destination: URL, orientation: Int?) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw MetadataError.unreadable("ImageIO can't open this image.")
        }
        let count = CGImageSourceGetCount(source)
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, count, nil) else {
            throw MetadataError.writeFailed("macOS can't write this image format.")
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            var frame: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
            if let orientation { frame[kCGImagePropertyOrientation] = orientation }
            if let compression = (properties["{TIFF}"] as? [String: Any])?["Compression"] {
                frame[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: compression]
            }
            CGImageDestinationAddImage(destinationRef, image, frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(destinationRef) else { throw MetadataError.writeFailed("Could not write the cleaned image.") }
    }
}
