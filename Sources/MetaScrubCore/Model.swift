import Foundation

/// Everything MetaScrub found in one file, grouped into sections for display and editing.
public struct MetadataReport: Sendable, Identifiable {
    public var id: URL { url }
    public var url: URL
    /// Human-readable format, e.g. "JPEG image".
    public var format: String
    /// Headline facts shown above the sections (dimensions, duration, pages).
    public var facts: [Fact]
    public var sections: [MetadataSection]
    /// A position found in the metadata (photo GPS, video location).
    public var location: GeoPoint?
    public var canEdit: Bool
    public var canClean: Bool
    /// Explains limits, e.g. "Saving re-encodes this image" or "Embedded metadata in this format is read-only".
    public var notes: [String]

    public init(url: URL, format: String, facts: [Fact] = [], sections: [MetadataSection] = [], location: GeoPoint? = nil,
                canEdit: Bool = false, canClean: Bool = false, notes: [String] = []) {
        self.url = url
        self.format = format
        self.facts = facts
        self.sections = sections
        self.location = location
        self.canEdit = canEdit
        self.canClean = canClean
        self.notes = notes
    }

    /// Entries stored inside the file itself (what Clean removes).
    public var embeddedEntries: [MetadataEntry] {
        sections.filter { $0.kind == .embedded }.flatMap(\.entries)
    }

    public var attributeEntries: [MetadataEntry] {
        sections.filter { $0.kind == .attributes }.flatMap(\.entries)
    }

    /// Short labels for what kind of personal data the file carries ("Location", "Device", "People").
    public var highlights: [Highlight] {
        var found = Set<Highlight>()
        if location != nil { found.insert(.location) }
        for entry in embeddedEntries + attributeEntries {
            if let highlight = entry.highlight { found.insert(highlight) }
        }
        return Highlight.allCases.filter(found.contains)
    }
}

public struct Fact: Hashable, Sendable {
    public var label: String
    public var value: String
    public var symbol: String

    public init(_ label: String, _ value: String, symbol: String) {
        self.label = label
        self.value = value
        self.symbol = symbol
    }
}

public struct GeoPoint: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }
}

public enum SectionKind: String, Sendable {
    /// Metadata stored inside the file's contents. Removed by Clean.
    case embedded
    /// Read-only facts about the encoded content (stream format, page size). Not personal metadata.
    case technical
    /// Name, size, dates and permissions kept by the file system.
    case file
    /// Extended attributes macOS attaches to files (download source, quarantine, tags).
    case attributes
    /// What Spotlight indexed for the file. Read-only, derived from the other kinds.
    case spotlight
}

public struct MetadataSection: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    public var kind: SectionKind
    public var entries: [MetadataEntry]
    /// Suggested fields for "Add Field"; empty when the section cannot gain entries.
    public var templates: [FieldTemplate]
    /// When set, the user may add a field with any name; the string describes the expected name.
    public var customFieldHint: String?
    public var note: String?

    public init(id: String, title: String, symbol: String, kind: SectionKind = .embedded, entries: [MetadataEntry] = [],
                templates: [FieldTemplate] = [], customFieldHint: String? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.entries = entries
        self.templates = templates
        self.customFieldHint = customFieldHint
        self.note = note
    }

    public var canAddFields: Bool { !templates.isEmpty || customFieldHint != nil }
}

public struct FieldTemplate: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String

    public init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }
}

public struct MetadataEntry: Sendable, Identifiable, Hashable {
    public var id: String { key }
    /// The handler's own key for the field (e.g. `TIT2`, `exif:DateTimeOriginal`, `dc:title`).
    public var key: String
    public var label: String
    public var value: String
    /// Raw key or extra detail shown in small print next to the label.
    public var detail: String?
    public var isEditable: Bool
    public var isRemovable: Bool
    public var isMultiline: Bool
    /// Embedded picture (cover art, thumbnail) shown instead of / next to the value.
    public var image: Data?
    public var highlight: Highlight?

    public init(key: String, label: String, value: String, detail: String? = nil, editable: Bool = false, removable: Bool = false,
                multiline: Bool? = nil, image: Data? = nil, highlight: Highlight? = nil, classify: Bool = true) {
        self.key = key
        self.label = label
        self.value = value
        self.detail = detail
        self.isEditable = editable
        self.isRemovable = removable
        self.isMultiline = multiline ?? (value.count > 80 || value.contains("\n"))
        self.image = image
        self.highlight = highlight ?? (classify ? Highlight.classify(key: key, label: label) : nil)
    }
}

/// Kinds of personal data worth pointing out before sharing a file.
public enum Highlight: String, CaseIterable, Sendable, Hashable {
    case location
    case device
    case people
    case history

    public var title: String {
        switch self {
        case .location: return "Location"
        case .device: return "Device"
        case .people: return "People"
        case .history: return "History"
        }
    }

    public var symbol: String {
        switch self {
        case .location: return "location.fill"
        case .device: return "camera.fill"
        case .people: return "person.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }

    static func classify(key: String, label: String) -> Highlight? {
        let text = (key + " " + label).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["gps", "location", "latitude", "longitude", "iso6709", "©xyz", "%a9xyz", "city", "country", "sublocation", "province"]) {
            return .location
        }
        if has(["make", "model", "serial", "lens", "hostcomputer", "host computer", "device", "camera", "software", "creatortool",
                "encoder", "application", "producer", "generator", "tool", "vendor"]) {
            return .device
        }
        if has(["artist", "author", "creator", "owner", "lastmodifiedby", "last modified by", "company", "manager", "person",
                "copyright", "rights", "email", "byline", "credit", "publisher", "contact", "engineer", "originator"]) {
            return .people
        }
        if has(["wherefroms", "where from", "quarantine", "downloaded", "history", "documentid", "instanceid", "derivedfrom",
                "revision", "editing", "totaltime", "template", "printed", "editing-cycles"]) {
            return .history
        }
        return nil
    }
}

/// One change requested in the viewer. Setting a key that does not exist adds it.
public struct MetadataEdit: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case set(String)
        case remove
    }

    public var sectionID: String
    public var key: String
    public var action: Action

    public init(sectionID: String, key: String, action: Action) {
        self.sectionID = sectionID
        self.key = key
        self.action = action
    }

    public static func set(_ sectionID: String, _ key: String, _ value: String) -> MetadataEdit {
        MetadataEdit(sectionID: sectionID, key: key, action: .set(value))
    }

    public static func remove(_ sectionID: String, _ key: String) -> MetadataEdit {
        MetadataEdit(sectionID: sectionID, key: key, action: .remove)
    }

    public var newValue: String? {
        if case .set(let value) = action { return value }
        return nil
    }
}

public struct CleanOptions: Codable, Hashable, Sendable {
    /// Remove extended attributes: download source, quarantine flag, Finder tags and comments.
    public var removeExtendedAttributes = true
    /// Keep embedded ICC color profiles so images look the same.
    public var keepColorProfile = true
    /// Keep the EXIF orientation so photos stay the right way up.
    public var keepOrientation = true
    /// Copy the original creation and modification dates onto the cleaned file.
    public var preserveFileDates = false

    public init(removeExtendedAttributes: Bool = true, keepColorProfile: Bool = true, keepOrientation: Bool = true,
                preserveFileDates: Bool = false) {
        self.removeExtendedAttributes = removeExtendedAttributes
        self.keepColorProfile = keepColorProfile
        self.keepOrientation = keepOrientation
        self.preserveFileDates = preserveFileDates
    }
}

public enum CleanDestination: Hashable, Sendable {
    case overwrite
    case folder(URL)
}

public struct CleanResult: Sendable {
    public var output: URL
    /// Embedded fields and extended attributes that are gone after cleaning.
    public var removedCount: Int
    /// Embedded fields still present (kept on purpose, e.g. orientation, or not removable in this format).
    public var remaining: [MetadataEntry]
    public var notes: [String]
}

public enum MetadataError: LocalizedError, Sendable {
    case unreadable(String)
    case corrupt(String)
    case unsupported(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message), .corrupt(let message), .unsupported(let message), .writeFailed(let message):
            return message
        }
    }
}
