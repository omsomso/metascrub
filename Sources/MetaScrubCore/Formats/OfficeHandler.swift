import Foundation

/// Office Open XML (docx, xlsx, pptx) and OpenDocument (odt, ods, odp) files: ZIP archives whose
/// document properties live in small XML parts.
struct OfficeHandler: FormatHandler {
    enum Kind { case ooxml, openDocument }
    let kind: Kind

    static let coreNamespaces = [
        "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
        "dc": "http://purl.org/dc/elements/1.1/",
        "dcterms": "http://purl.org/dc/terms/",
        "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    ]
    static let appNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"

    static let coreLabels: [String: String] = [
        "dc:title": "Title", "dc:subject": "Subject", "dc:creator": "Author", "cp:keywords": "Keywords", "dc:description": "Comments",
        "cp:lastModifiedBy": "Last modified by", "cp:revision": "Revision", "dcterms:created": "Created", "dcterms:modified": "Modified",
        "cp:category": "Category", "cp:contentStatus": "Status", "dc:language": "Language", "cp:version": "Version",
        "dc:identifier": "Identifier", "cp:lastPrinted": "Last printed", "cp:contentType": "Content type",
    ]
    static let appEditable: Set<String> = ["Company", "Manager", "Application", "AppVersion", "Template", "HyperlinkBase", "TotalTime"]
    /// app.xml fields Clean removes; statistics and layout flags stay.
    static let appPersonal: Set<String> = ["Company", "Manager", "Application", "AppVersion", "Template", "HyperlinkBase", "TotalTime"]
    static let odfLabels: [String: String] = [
        "meta:generator": "Generator", "dc:title": "Title", "dc:description": "Description", "dc:subject": "Subject",
        "meta:keyword": "Keyword", "meta:initial-creator": "Created by", "dc:creator": "Last modified by",
        "meta:creation-date": "Created", "dc:date": "Modified", "meta:editing-cycles": "Revision",
        "meta:editing-duration": "Editing time", "meta:print-date": "Last printed", "meta:printed-by": "Printed by",
        "dc:language": "Language", "meta:template": "Template", "meta:document-statistic": "Statistics",
    ]

    struct Parts {
        var archive: ZipArchive
        var core: String
        var app: String
        var custom: String
        var thumbnail: String?
    }

    func parts(_ url: URL) throws -> Parts {
        let archive = try ZipArchive(try mappedData(url))
        if kind == .openDocument {
            let thumbnail = archive.entries.first { $0.name.hasPrefix("Thumbnails/") }?.name
            return Parts(archive: archive, core: "meta.xml", app: "", custom: "", thumbnail: thumbnail)
        }
        var targets: [String: String] = [:]
        if let rels = try archive.contents("_rels/.rels"), let xml = try? XMLDocument(data: rels) {
            for case let element as XMLElement in (try? xml.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
                guard let type = element.attribute(forName: "Type")?.stringValue,
                      var target = element.attribute(forName: "Target")?.stringValue else { continue }
                if target.hasPrefix("/") { target.removeFirst() }
                targets[String(type.split(separator: "/").last ?? "")] = target
            }
        }
        return Parts(archive: archive, core: targets["core-properties"] ?? "docProps/core.xml",
                     app: targets["extended-properties"] ?? "docProps/app.xml", custom: targets["custom-properties"] ?? "docProps/custom.xml",
                     thumbnail: targets["thumbnail"].flatMap { archive.entry($0) != nil ? $0 : nil })
    }

    static func xml(_ data: Data?) -> XMLDocument? {
        data.flatMap { try? XMLDocument(data: $0, options: [.nodePreserveAll]) }
    }

    static func serialize(_ document: XMLDocument) -> Data {
        document.characterEncoding = "UTF-8"
        document.isStandalone = true
        return document.xmlData(options: [.nodeCompactEmptyElement])
    }

    /// Direct children of the element that holds the properties.
    static func propertyElements(_ document: XMLDocument, kind: Kind) -> [XMLElement] {
        let container: XMLElement?
        if kind == .openDocument {
            container = ((try? document.nodes(forXPath: "//*[local-name()='meta' and parent::*[local-name()='document-meta']]")) ?? [])
                .first as? XMLElement
        } else {
            container = document.rootElement()
        }
        return container?.children?.compactMap { $0 as? XMLElement } ?? []
    }

    // MARK: Reading

    func read(_ url: URL) async throws -> FormatReport {
        let parts = try parts(url)
        let archive = parts.archive
        let ext = url.pathExtension.lowercased()
        let names: [String: String] = ["docx": "Word document", "xlsx": "Excel workbook", "pptx": "PowerPoint presentation",
                                       "odt": "OpenDocument text", "ods": "OpenDocument spreadsheet", "odp": "OpenDocument presentation"]
        var report = FormatReport(format: names[ext] ?? (url.typeIdentifier?.localizedDescription ?? "Office document").capitalizedFirst,
                                  canEdit: true, canClean: true)
        if kind == .openDocument {
            readODF(parts, into: &report)
        } else {
            readOOXML(parts, into: &report)
        }
        if let thumbnail = parts.thumbnail, let image = try? archive.contents(thumbnail) {
            report.sections.append(MetadataSection(id: "office.thumbnail", title: "Preview", symbol: "photo", entries: [
                MetadataEntry(key: thumbnail, label: "Thumbnail", value: "First page preview · \(Format.bytes(image.count))",
                              multiline: false, image: image),
            ], note: "A picture of the first page, saved for Finder and Quick Look. Clean removes it."))
        }
        let stamped = archive.entries.filter { !$0.hasNeutralDate }.compactMap(\.modified)
        if let newest = stamped.max() {
            report.sections.append(MetadataSection(id: "office.zip", title: "Archive", symbol: "doc.zipper", entries: [
                MetadataEntry(key: "zip:dates", label: "Saved parts dated", value: Format.date(newest), highlight: .history),
            ], note: "The document is a ZIP archive whose parts carry save times. Clean resets them."))
        }
        report.facts.append(Fact("Parts", "\(archive.entries.count) files inside", symbol: "doc.zipper"))
        return report
    }

    private func readOOXML(_ parts: Parts, into report: inout FormatReport) {
        let archive = parts.archive
        var core: [MetadataEntry] = []
        if let document = Self.xml(try? archive.contents(parts.core)) {
            for element in Self.propertyElements(document, kind: .ooxml) {
                guard let name = element.name else { continue }
                core.append(MetadataEntry(key: name, label: Self.coreLabels[name] ?? Format.words(element.localName ?? name),
                                          value: element.stringValue ?? "", detail: name, editable: true, removable: true))
            }
        }
        let missing = ["dc:title", "dc:subject", "dc:creator", "cp:keywords", "dc:description", "cp:lastModifiedBy", "cp:category"]
            .filter { key in !core.contains { $0.key == key } }
        report.sections.append(MetadataSection(id: "office.core", title: "Document Properties", symbol: "doc.text", entries: core,
                                               templates: missing.map { FieldTemplate($0, Self.coreLabels[$0]!) }))

        var app: [MetadataEntry] = []
        if let document = Self.xml(try? archive.contents(parts.app)) {
            for element in Self.propertyElements(document, kind: .ooxml) {
                guard let name = element.name else { continue }
                let values = ((try? element.nodes(forXPath: ".//*[local-name()='lpstr' or local-name()='lpwstr']")) ?? []).compactMap(\.stringValue)
                if element.children?.contains(where: { $0.kind == .element }) == true {
                    if name == "TitlesOfParts", !values.isEmpty {
                        app.append(MetadataEntry(key: name, label: "Part titles", value: values.joined(separator: ", "), detail: name))
                    }
                    continue
                }
                let value = element.stringValue ?? ""
                if ["Pages", "Words", "Slides", "Characters"].contains(name), let number = Int(value), number > 0 {
                    report.facts.append(Fact(name, number.formatted(), symbol: name == "Slides" ? "rectangle.on.rectangle" : "text.word.spacing"))
                }
                let label = name == "TotalTime" ? "Editing time (minutes)" : Format.words(name)
                app.append(MetadataEntry(key: name, label: label, value: value, detail: name, editable: Self.appEditable.contains(name),
                                         removable: Self.appEditable.contains(name)))
            }
        }
        if !app.isEmpty {
            let missing = ["Company", "Manager"].filter { key in !app.contains { $0.key == key } }
            report.sections.append(MetadataSection(id: "office.app", title: "Application Properties", symbol: "app.badge", entries: app,
                                                   templates: missing.map { FieldTemplate($0, $0) }))
        }

        if let document = Self.xml(try? archive.contents(parts.custom)) {
            let entries = Self.propertyElements(document, kind: .ooxml).compactMap { element -> MetadataEntry? in
                guard let name = element.attribute(forName: "name")?.stringValue else { return nil }
                return MetadataEntry(key: "custom:\(name)", label: name, value: element.stringValue ?? "", detail: "custom", editable: true, removable: true)
            }
            report.sections.append(MetadataSection(id: "office.custom", title: "Custom Properties", symbol: "slider.horizontal.3", entries: entries,
                                                   customFieldHint: "Property name"))
        }
        report.notes.append("Names inside the document itself (comment and tracked-change authors) aren't changed.")
    }

    private func readODF(_ parts: Parts, into report: inout FormatReport) {
        var entries: [MetadataEntry] = []
        var seen: [String: Int] = [:]
        if let document = Self.xml(try? parts.archive.contents(parts.core)) {
            for element in Self.propertyElements(document, kind: .openDocument) {
                guard let name = element.name else { continue }
                var key = name
                var label = Self.odfLabels[name] ?? Format.words(element.localName ?? name)
                var value = element.stringValue ?? ""
                var editable = true
                switch name {
                case "meta:user-defined":
                    let field = element.attribute(forName: "meta:name")?.stringValue ?? "Field"
                    key = "user:\(field)"
                    label = field
                case "meta:document-statistic":
                    value = (element.attributes ?? []).compactMap { attribute in
                        attribute.localName.map { "\(Format.words($0)) \(attribute.stringValue ?? "")" }
                    }.joined(separator: ", ")
                    editable = false
                case "meta:template":
                    value = element.attribute(forName: "xlink:href")?.stringValue ?? element.attribute(forName: "xlink:title")?.stringValue ?? ""
                    editable = false
                default:
                    break
                }
                let occurrence = seen[key, default: 0]
                seen[key] = occurrence + 1
                if occurrence > 0 { key += "#\(occurrence)" }
                entries.append(MetadataEntry(key: key, label: label, value: value, detail: name, editable: editable,
                                             removable: name != "meta:document-statistic"))
            }
        }
        let missing = ["dc:title", "dc:subject", "dc:description", "meta:initial-creator", "dc:creator"]
            .filter { key in !entries.contains { $0.key == key } }
        report.sections.append(MetadataSection(id: "office.meta", title: "Document Properties", symbol: "doc.text", entries: entries,
                                               templates: missing.map { FieldTemplate($0, Self.odfLabels[$0]!) },
                                               customFieldHint: "Custom field name"))
    }

    // MARK: Writing

    func clean(_ source: URL, to destination: URL, options: CleanOptions) async throws -> [String] {
        let parts = try parts(source)
        let archive = parts.archive
        var changes: [String: ZipArchive.Change] = [:]
        if kind == .openDocument {
            if let document = Self.xml(try archive.contents(parts.core)) {
                for element in Self.propertyElements(document, kind: .openDocument) where element.name != "meta:document-statistic" {
                    element.detach()
                }
                changes[parts.core] = .replace(Self.serialize(document))
            }
            if parts.thumbnail != nil {
                for entry in archive.entries where entry.name.hasPrefix("Thumbnails/") { changes[entry.name] = .remove }
                if let manifest = Self.xml(try archive.contents("META-INF/manifest.xml")) {
                    let fileEntries = (try? manifest.nodes(forXPath: "//*[local-name()='file-entry']")) ?? []
                    for case let element as XMLElement in fileEntries {
                        if element.attribute(forName: "manifest:full-path")?.stringValue?.hasPrefix("Thumbnails/") == true { element.detach() }
                    }
                    changes["META-INF/manifest.xml"] = .replace(Self.serialize(manifest))
                }
            }
        } else {
            if let document = Self.xml(try archive.contents(parts.core)) {
                for element in Self.propertyElements(document, kind: .ooxml) { element.detach() }
                changes[parts.core] = .replace(Self.serialize(document))
            }
            if let document = Self.xml(try archive.contents(parts.app)) {
                for element in Self.propertyElements(document, kind: .ooxml) where Self.appPersonal.contains(element.name ?? "") {
                    element.detach()
                }
                changes[parts.app] = .replace(Self.serialize(document))
            }
            if let document = Self.xml(try archive.contents(parts.custom)) {
                for element in Self.propertyElements(document, kind: .ooxml) { element.detach() }
                changes[parts.custom] = .replace(Self.serialize(document))
            }
            if let thumbnail = parts.thumbnail {
                changes[thumbnail] = .remove
                if let rels = Self.xml(try archive.contents("_rels/.rels")) {
                    for case let element as XMLElement in (try? rels.nodes(forXPath: "//*[local-name()='Relationship']")) ?? []
                    where element.attribute(forName: "Type")?.stringValue?.hasSuffix("/thumbnail") == true {
                        element.detach()
                    }
                    changes["_rels/.rels"] = .replace(Self.serialize(rels))
                }
                if let types = Self.xml(try archive.contents("[Content_Types].xml")) {
                    for case let element as XMLElement in (try? types.nodes(forXPath: "//*[local-name()='Override']")) ?? []
                    where element.attribute(forName: "PartName")?.stringValue == "/" + thumbnail {
                        element.detach()
                    }
                    changes["[Content_Types].xml"] = .replace(Self.serialize(types))
                }
            }
        }
        try archive.write(to: destination, changes: changes, neutralDates: true)
        return []
    }

    func apply(_ edits: [MetadataEdit], to source: URL, writingTo destination: URL) async throws -> [String] {
        let parts = try parts(source)
        let archive = parts.archive
        var changes: [String: ZipArchive.Change] = [:]
        let bySection = Dictionary(grouping: edits, by: \.sectionID)
        for (section, sectionEdits) in bySection {
            switch section {
            case "office.core", "office.meta":
                guard let document = Self.xml(try archive.contents(parts.core)) else {
                    throw MetadataError.unsupported("This document has no properties part to edit.")
                }
                try applyProperties(sectionEdits, to: document, section: section)
                changes[parts.core] = .replace(Self.serialize(document))
            case "office.app":
                guard let document = Self.xml(try archive.contents(parts.app)) else { throw MetadataError.unsupported("No application properties.") }
                try applyProperties(sectionEdits, to: document, section: section)
                changes[parts.app] = .replace(Self.serialize(document))
            case "office.custom":
                guard let document = Self.xml(try archive.contents(parts.custom)) else { throw MetadataError.unsupported("No custom properties.") }
                try applyCustom(sectionEdits, to: document)
                changes[parts.custom] = .replace(Self.serialize(document))
            default:
                throw MetadataError.unsupported("This section is read-only.")
            }
        }
        try archive.write(to: destination, changes: changes, neutralDates: false)
        return []
    }

    private func applyProperties(_ edits: [MetadataEdit], to document: XMLDocument, section: String) throws {
        let elements = Self.propertyElements(document, kind: kind)
        // Rebuild the same keys the reader produced so `#n` duplicates resolve to the right element.
        var keyed: [String: XMLElement] = [:]
        var seen: [String: Int] = [:]
        for element in elements {
            guard let name = element.name else { continue }
            var key = name
            if name == "meta:user-defined" { key = "user:\(element.attribute(forName: "meta:name")?.stringValue ?? "Field")" }
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            keyed[occurrence > 0 ? "\(key)#\(occurrence)" : key] = element
        }
        let container = elements.first?.parent as? XMLElement
            ?? (kind == .openDocument
                ? ((try? document.nodes(forXPath: "//*[local-name()='meta' and parent::*[local-name()='document-meta']]")) ?? []).first as? XMLElement
                : document.rootElement())
        for edit in edits {
            if let element = keyed[edit.key] {
                if let value = edit.newValue { element.stringValue = value } else { element.detach() }
                continue
            }
            guard let value = edit.newValue, let container else { continue }
            container.addChild(newElement(edit.key, value: value, section: section))
        }
    }

    private func newElement(_ key: String, value: String, section: String) -> XMLElement {
        if kind == .openDocument {
            let odf = ["meta": "urn:oasis:names:tc:opendocument:xmlns:meta:1.0", "dc": "http://purl.org/dc/elements/1.1/"]
            if !key.contains(":") || key.hasPrefix("user:") {
                let name = key.hasPrefix("user:") ? String(key.dropFirst(5)) : key
                let element = XMLElement(name: "meta:user-defined", uri: odf["meta"])
                element.addAttribute(XMLNode.attribute(withName: "meta:name", uri: odf["meta"]!, stringValue: name) as! XMLNode)
                element.stringValue = value
                return element
            }
            let prefix = String(key.split(separator: ":").first ?? "")
            let element = XMLElement(name: key, uri: odf[prefix])
            element.stringValue = value
            return element
        }
        if section == "office.app" {
            let element = XMLElement(name: key, uri: Self.appNamespace)
            element.stringValue = value
            return element
        }
        let prefix = String(key.split(separator: ":").first ?? "")
        let element = XMLElement(name: key, uri: Self.coreNamespaces[prefix])
        element.stringValue = value
        return element
    }

    private func applyCustom(_ edits: [MetadataEdit], to document: XMLDocument) throws {
        guard let root = document.rootElement() else { return }
        let properties = Self.propertyElements(document, kind: .ooxml)
        var nextID = (properties.compactMap { Int($0.attribute(forName: "pid")?.stringValue ?? "") }.max() ?? 1) + 1
        for edit in edits {
            let name = edit.key.hasPrefix("custom:") ? String(edit.key.dropFirst(7)) : edit.key
            if let property = properties.first(where: { $0.attribute(forName: "name")?.stringValue == name }) {
                if let value = edit.newValue {
                    let child = property.children?.first as? XMLElement
                    if let child { child.stringValue = value } else { property.stringValue = value }
                } else {
                    property.detach()
                }
            } else if let value = edit.newValue {
                let property = XMLElement(name: "property", uri: "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties")
                property.addAttribute(XMLNode.attribute(withName: "fmtid", stringValue: "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}") as! XMLNode)
                property.addAttribute(XMLNode.attribute(withName: "pid", stringValue: "\(nextID)") as! XMLNode)
                property.addAttribute(XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode)
                nextID += 1
                let text = XMLElement(name: "vt:lpwstr", uri: "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes")
                text.stringValue = value
                property.addChild(text)
                root.addChild(property)
            }
        }
    }
}
