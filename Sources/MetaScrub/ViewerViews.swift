import AppKit
import MapKit
import MetaScrubCore
import SwiftUI

struct ViewerHome: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        DropZone(symbol: "doc.text.magnifyingglass", title: "Drop files to see their metadata",
                 subtitle: "Every field MetaScrub finds is laid out by section. Edit values, add or remove fields, then save over the file or as a copy.",
                 buttonTitle: "Open Files…", isTargeted: isTargeted) { model.chooseFiles(for: .viewer) }
            .dropDestination(for: URL.self) { urls, _ in
                model.openInViewer(urls)
                return true
            } isTargeted: { isTargeted = $0 }
            .navigationTitle("Viewer")
    }
}

struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    let fileID: UUID
    @State private var search = ""
    @State private var isTargeted = false

    var body: some View {
        if let file = model.viewerFiles.first(where: { $0.id == fileID }) {
            content(file)
                .navigationTitle(file.url.lastPathComponent)
                .navigationSubtitle(file.report?.format ?? "")
                .searchable(text: $search, placement: .toolbar, prompt: "Filter fields")
                .toolbar {
                    ToolbarItemGroup {
                        Button { model.sendToCleaner(fileID) } label: { Label("Send to Cleaner", systemImage: "wand.and.sparkles") }
                            .help("Add this file to the Cleaner")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                            .help("Show in Finder")
                        Button { Task { await model.load(fileID) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                            .help("Read the file again (discards nothing; unsaved edits stay)")
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.openInViewer(urls)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            ViewerHome()
        }
    }

    @ViewBuilder private func content(_ file: AppModel.ViewerFile) -> some View {
        if let report = file.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeaderCard(file: file, report: report)
                    ForEach(report.notes + file.saveNotes, id: \.self) { NoteBanner(text: $0) }
                    if let location = report.location {
                        LocationCard(location: location, canRemove: report.canEdit && hasRemovableLocation(report)) {
                            model.removeLocation(fileID)
                        }
                    }
                    let sections = visibleSections(report)
                    let empty = sections.filter { isEmptyAddable($0) }
                    let filled = sections.filter { !isEmptyAddable($0) }
                    ForEach(filled.filter { $0.kind == .embedded || $0.kind == .derived }) { section in
                        SectionCard(fileID: fileID, section: section, filter: search, editable: report.canEdit)
                    }
                    if !empty.isEmpty && report.canEdit {
                        AddMetadataCard(fileID: fileID, sections: empty)
                    }
                    ForEach(filled.filter { $0.kind != .embedded && $0.kind != .derived }) { section in
                        SectionCard(fileID: fileID, section: section, filter: search, editable: report.canEdit || isFileLevel(section))
                    }
                    if visibleSections(report).isEmpty && !search.isEmpty {
                        Text("No fields match “\(search)”.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(24)
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
            }
            .safeAreaPadding(.bottom, file.hasChanges || file.saveError != nil ? 76 : 0)
            .overlay(alignment: .bottom) {
                if file.hasChanges || file.saveError != nil {
                    SaveBar(file: file)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: file.hasChanges)
        } else {
            ProgressView("Reading \(file.url.lastPathComponent)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isFileLevel(_ section: MetadataSection) -> Bool { section.kind == .file || section.kind == .attributes }

    /// Sections with nothing in them yet; they're offered together in one compact card.
    private func isEmptyAddable(_ section: MetadataSection) -> Bool {
        section.kind == .embedded && section.canAddFields && section.entries.isEmpty
            && model.addedEntries(fileID, section.id).isEmpty && search.isEmpty
    }

    private func hasRemovableLocation(_ report: MetadataReport) -> Bool {
        report.embeddedEntries.contains { $0.highlight == .location && $0.isRemovable }
    }

    private func visibleSections(_ report: MetadataReport) -> [MetadataSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return report.sections }
        return report.sections.compactMap { section in
            var filtered = section
            filtered.entries = section.entries.filter {
                $0.label.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query)
                    || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
            }
            return filtered.entries.isEmpty ? nil : filtered
        }
    }
}

struct HeaderCard: View {
    let file: AppModel.ViewerFile
    let report: MetadataReport

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let thumbnail = file.thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                } else {
                    FileIcon(url: file.url, size: 96)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 8) {
                Text(file.url.lastPathComponent)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(report.format) · \(file.url.fileSizeText)")
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(report.facts, id: \.self) { FactChip(fact: $0) }
                }
                let highlights = report.highlights
                if !highlights.isEmpty {
                    HStack(spacing: 6) {
                        Text("Contains").font(.caption).foregroundStyle(.secondary)
                        ForEach(highlights, id: \.self) { HighlightChip(highlight: $0) }
                    }
                    .padding(.top, 2)
                } else {
                    Label("No personal metadata spotted", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .card()
    }
}

struct NoteBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Coordinates, with an on-demand map (loading map tiles tells Apple's map service roughly where you're looking).
struct LocationCard: View {
    let location: GeoPoint
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var showingMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.red.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("This file records where it was made").font(.headline)
                    Text(coordinates).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(showingMap ? "Hide Map" : "Show Map") { withAnimation(.snappy) { showingMap.toggle() } }
                    .buttonStyle(.glass)
                    .help("Loads map tiles from Apple Maps")
                Button("Open in Maps") {
                    if let url = URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Location") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
                if canRemove {
                    Button("Remove Location", role: .destructive, action: onRemove)
                        .buttonStyle(.glass)
                        .help("Marks every location field for removal; press Save to apply")
                }
            }
            .padding(14)
            if showingMap {
                let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                    Marker("", systemImage: "camera.fill", coordinate: coordinate).tint(.red)
                }
                .frame(height: 220)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
            }
        }
        .card()
    }

    private var coordinates: String {
        var text = String(format: "%.5f° %@, %.5f° %@", abs(location.latitude), location.latitude >= 0 ? "N" : "S",
                          abs(location.longitude), location.longitude >= 0 ? "E" : "W")
        if let altitude = location.altitude { text += String(format: " · %.0f m", altitude) }
        return text
    }
}

struct SectionCard: View {
    @Environment(AppModel.self) private var model
    let fileID: UUID
    let section: MetadataSection
    let filter: String
    let editable: Bool
    var body: some View {
        let added = model.addedEntries(fileID, section.id)
        let collapsed = model.collapsedSections.contains(section.id) && filter.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            header(count: section.entries.count + added.count, collapsed: collapsed)
            if !collapsed {
                if section.entries.isEmpty && added.isEmpty {
                    Text(editable && section.canAddFields ? "No fields yet. Use Add Field to create one." : "No fields.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                ForEach(section.entries + added) { entry in
                    Divider().padding(.leading, 16)
                    EntryRow(fileID: fileID, sectionID: section.id, entry: entry, editable: editable,
                             isNew: added.contains { $0.key == entry.key })
                }
                if let note = section.note {
                    Divider().padding(.leading, 16)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .card()
    }

    private func header(count: Int, collapsed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(section.title).font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: Capsule())
            if section.kind == .technical {
                Text(section.entries.contains(where: \.isEditable) && editable ? "Technical" : "Read-only")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if section.kind == .derived {
                Text("Summary").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if editable && section.canAddFields && !collapsed { AddFieldMenu(fileID: fileID, section: section) }
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if model.collapsedSections.contains(section.id) {
                        model.collapsedSections.remove(section.id)
                    } else {
                        model.collapsedSections.insert(section.id)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Expand" : "Collapse")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tint: Color {
        switch section.kind {
        case .embedded: return section.entries.first?.highlight == .generation ? .pink : .accentColor
        case .derived: return .pink
        case .technical: return .gray
        case .file: return .teal
        case .attributes: return .indigo
        case .spotlight: return .gray
        }
    }

}

/// "Add Field" button: the section's suggested fields, plus a custom name where the format allows one.
struct AddFieldMenu: View {
    @Environment(AppModel.self) private var model
    let fileID: UUID
    let section: MetadataSection
    @State private var addingCustom = false
    @State private var customName = ""

    var body: some View {
        let present = Set(section.entries.map(\.key) + model.addedEntries(fileID, section.id).map(\.key))
        let templates = section.templates.filter { !present.contains($0.key) }
        Menu {
            ForEach(templates) { template in
                Button(template.label) { model.addField(fileID, section.id, key: template.key, label: template.label) }
            }
            if section.customFieldHint != nil {
                if !templates.isEmpty { Divider() }
                Button("Custom Field…") {
                    customName = ""
                    addingCustom = true
                }
            }
        } label: {
            Label("Add Field", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
        .disabled(templates.isEmpty && section.customFieldHint == nil)
        .popover(isPresented: $addingCustom, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New field in \(section.title)").font(.headline)
                TextField(section.customFieldHint ?? "Name", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(addCustom)
                HStack {
                    Spacer()
                    Button("Cancel") { addingCustom = false }
                    Button("Add", action: addCustom)
                        .buttonStyle(.borderedProminent)
                        .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func addCustom() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addField(fileID, section.id, key: name, label: name)
        addingCustom = false
    }
}

/// Empty sections, offered in one card so they don't crowd the fields that exist.
struct AddMetadataCard: View {
    let fileID: UUID
    let sections: [MetadataSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Add Metadata").font(.headline)
                Text("Sections with no fields yet").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ForEach(sections) { section in
                Divider().padding(.leading, 16)
                HStack(spacing: 10) {
                    Image(systemName: section.symbol).foregroundStyle(.secondary).frame(width: 26)
                    Text(section.title).foregroundStyle(.secondary)
                    Spacer()
                    AddFieldMenu(fileID: fileID, section: section)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .card()
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let fileID: UUID
    let sectionID: String
    let entry: MetadataEntry
    let editable: Bool
    let isNew: Bool
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let change = model.change(fileID, sectionID, entry.key)
        let removed = change != nil && change?.value == nil
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let highlight = entry.highlight {
                        Circle().fill(highlight.color).frame(width: 6, height: 6).help(highlight.title)
                    }
                    Text(entry.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let detail = entry.detail, detail != entry.label {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 210, alignment: .leading)

            value(removed: removed)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing(change: change, removed: removed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(rowTint(change: change, removed: removed))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Value") { Clipboard.copy(model.displayedValue(fileID, sectionID, entry)) }
            Button("Copy Name") { Clipboard.copy(entry.detail ?? entry.label) }
        }
    }

    /// Whole workflows run to hundreds of kilobytes; the row shows the start and Copy takes all of it.
    private var isLong: Bool { entry.value.count > 600 }

    private var shownValue: String {
        entry.value.count > 3000 ? String(entry.value.prefix(3000)) + "\n…" : entry.value
    }

    @ViewBuilder private func value(removed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = entry.image, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 160, maxHeight: 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(removed ? 0.35 : 1)
            }
            if editable && entry.isEditable && !removed {
                TextField(isNew ? "Value" : "", text: binding, axis: entry.isMultiline ? .vertical : .horizontal)
                    .textFieldStyle(.plain)
                    .lineLimit(entry.isMultiline ? 1...10 : 1...1)
                    .focused($focused)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(focused ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(hovering ? 0.10 : 0.06))
                    }
                    .overlay {
                        // Outline only while typing; at rest the tint alone marks the field.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(focused ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
                    }
                    .padding(.horizontal, -6)
                    .help("Click to edit")
            } else {
                Text(entry.value.isEmpty ? "—" : shownValue)
                    .font(isLong ? .callout.monospaced() : .body)
                    .foregroundStyle(entry.value.isEmpty ? .tertiary : .primary)
                    .strikethrough(removed)
                    .opacity(removed ? 0.45 : 1)
                    .textSelection(.enabled)
                    .lineLimit(entry.isMultiline ? 12 : 3)
                if isLong {
                    Button { Clipboard.copy(entry.value) } label: {
                        Label("Copy \(entry.value.count > 1500 ? "all \(Format.characters(entry.value.count))" : "value")", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func trailing(change: AppModel.PendingChange?, removed: Bool) -> some View {
        HStack(spacing: 4) {
            if removed {
                Text("Will be removed").font(.caption).foregroundStyle(.red)
                Button("Undo") { model.restore(fileID, sectionID, entry) }
                    .buttonStyle(.link)
                    .font(.caption)
            } else if isNew {
                Text("New").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            } else if change != nil {
                Button { model.restore(fileID, sectionID, entry) } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("Undo this change")
            }
            if editable && entry.isRemovable && !removed {
                Button { model.remove(fileID, sectionID, entry) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.borderless)
                .help(isNew ? "Discard this new field" : "Remove this field")
                .opacity(hovering ? 1 : 0)
            } else if !editable || !entry.isRemovable {
                Color.clear.frame(width: 16, height: 1)
            }
        }
        .frame(minWidth: 24, alignment: .trailing)
    }

    private func rowTint(change: AppModel.PendingChange?, removed: Bool) -> Color {
        if removed { return Color.red.opacity(0.06) }
        if change != nil { return Color.accentColor.opacity(0.07) }
        return .clear
    }

    private var binding: Binding<String> {
        Binding(get: { model.displayedValue(fileID, sectionID, entry) },
                set: { model.setValue(fileID, sectionID, entry, $0) })
    }
}

struct SaveBar: View {
    @Environment(AppModel.self) private var model
    let file: AppModel.ViewerFile

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                Image(systemName: file.saveError == nil ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(file.saveError == nil ? Color.accentColor : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.changes.count == 1 ? "1 unsaved change" : "\(file.changes.count) unsaved changes")
                        .font(.callout.weight(.medium))
                    if let error = file.saveError {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Text("Save rewrites \(file.url.lastPathComponent).").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button("Revert") { model.revert(file.id) }
                    .buttonStyle(.glass)
                    .disabled(file.isSaving)
                Button("Save As…") { model.saveAs(file.id) }
                    .buttonStyle(.glass)
                    .disabled(file.isSaving || !file.hasChanges)
                Button {
                    Task { await model.save(file.id) }
                } label: {
                    if file.isSaving {
                        ProgressView().controlSize(.small).padding(.horizontal, 10)
                    } else {
                        Text("Save").padding(.horizontal, 8)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(file.isSaving || !file.hasChanges)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: 760)
    }
}
