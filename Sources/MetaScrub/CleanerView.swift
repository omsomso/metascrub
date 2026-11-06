import AppKit
import MetaScrubCore
import SwiftUI

struct CleanerView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var confirmingReplace = false
    @AppStorage("skipReplaceConfirmation") private var skipReplaceConfirmation = false

    var body: some View {
        Group {
            if model.cleanItems.isEmpty {
                DropZone(symbol: "wand.and.sparkles", title: "Drop files to remove their metadata",
                         subtitle: "Location, camera and device details, authors, comments, edit history and download records. Drop as many files or folders as you like.",
                         buttonTitle: "Choose Files…", isTargeted: isTargeted) { model.chooseFiles(for: .cleaner) }
            } else {
                List {
                    ForEach(model.cleanItems) { item in
                        CleanRow(item: item)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.bottom, 84)
            }
        }
        .overlay(alignment: .bottom) {
            if !model.cleanItems.isEmpty {
                CleanerBar(onClean: startClean)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addToCleaner(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle("Cleaner")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseFiles(for: .cleaner) } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add files or folders to clean")
                Button { model.clearCleaner() } label: { Label("Clear List", systemImage: "trash") }
                    .help("Remove all files from the list (the files themselves are not touched)")
                    .disabled(model.cleanItems.isEmpty || model.isCleaning)
            }
        }
        .confirmationDialog("Replace \(model.pendingCleanCount == 1 ? "the original file" : "\(model.pendingCleanCount) original files")?",
                            isPresented: $confirmingReplace) {
            Button("Remove Metadata", role: .destructive) { Task { await model.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The originals are rewritten without their metadata. This can't be undone. Choose “Save copies to folder” to keep them.")
        }
        .dialogSuppressionToggle("Don't ask again", isSuppressed: $skipReplaceConfirmation)
    }

    private var subtitle: String {
        guard !model.cleanItems.isEmpty else { return "" }
        let files = model.cleanItems.count == 1 ? "1 file" : "\(model.cleanItems.count) files"
        return model.isScanning ? "\(files) · reading…" : "\(files) · \(model.totalFoundCount) metadata fields"
    }

    private func startClean() {
        if model.destinationMode == .overwrite && !skipReplaceConfirmation {
            confirmingReplace = true
        } else {
            Task { await model.clean() }
        }
    }
}

struct CleanRow: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.CleanItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(url: outputURL, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(highlights, id: \.self) { HighlightChip(highlight: $0, compact: true) }
                }
            }
            Spacer(minLength: 12)
            status
            Button { model.removeCleanItem(item.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the list")
            .opacity(hovering && !isBusy ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in Viewer") { model.openInViewer([outputURL]) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
            Divider()
            Button("Remove from List") { model.removeCleanItem(item.id) }.disabled(isBusy)
        }
    }

    private var outputURL: URL {
        if case .done(let result) = item.state { return result.output }
        return item.url
    }

    private var isBusy: Bool {
        if case .cleaning = item.state { return true }
        return false
    }

    /// Before cleaning: what the file holds. Afterwards: only what is still there.
    private var highlights: [Highlight] {
        if case .done(let result) = item.state {
            let left = Set(result.remaining.compactMap(\.highlight))
            return Highlight.allCases.filter(left.contains)
        }
        return item.report?.highlights ?? []
    }

    private var detail: String {
        var parts = [item.report?.format ?? "Reading…", item.url.fileSizeText]
        if case .done(let result) = item.state, result.output != item.url {
            parts.append(result.output.lastPathComponent == item.url.lastPathComponent
                         ? "copy in “\(result.output.deletingLastPathComponent().lastPathComponent)”"
                         : "copy saved as \(result.output.lastPathComponent)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .scanning:
            ProgressView().controlSize(.small)
        case .ready:
            let count = item.removableCount(model.options)
            Text(count == 0 ? "Nothing found" : "\(count) to remove")
                .font(.callout.monospacedDigit())
                .foregroundStyle(count == 0 ? .tertiary : .secondary)
                .help(item.report?.canClean == false && !(item.report?.embeddedEntries.isEmpty ?? true)
                      ? "This format's internal metadata can't be removed yet; only file-system metadata will be cleaned." : "")
        case .cleaning:
            ProgressView().controlSize(.small)
        case .done(let result):
            VStack(alignment: .trailing, spacing: 2) {
                Label(result.removedCount == 1 ? "Removed 1" : "Removed \(result.removedCount)", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                if !result.remaining.isEmpty || !result.notes.isEmpty {
                    Text(result.remaining.isEmpty ? "See note" : "Kept \(result.remaining.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(([result.remaining.isEmpty ? nil : "Kept: " + result.remaining.map(\.label).joined(separator: ", ")] + result.notes)
                .compactMap { $0 }.joined(separator: "\n"))
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}

/// Floating glass bar with the output choice, options and the Clean button.
struct CleanerBar: View {
    @Environment(AppModel.self) private var model
    let onClean: () -> Void
    @State private var showingOptions = false

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer {
            HStack(spacing: 12) {
                Picker("Output", selection: $model.destinationMode) {
                    Text("Replace originals").tag(AppModel.DestinationMode.overwrite)
                    Text("Save copies to folder").tag(AppModel.DestinationMode.folder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if model.destinationMode == .folder {
                    Button { model.chooseOutputFolder() } label: {
                        Label(model.outputFolder?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                    }
                    .buttonStyle(.glass)
                    .help(model.outputFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Pick where cleaned copies go")
                }

                Button { showingOptions.toggle() } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.glass)
                .popover(isPresented: $showingOptions, arrowEdge: .top) { OptionsPopover() }

                Spacer(minLength: 8)

                summary

                Button(action: onClean) {
                    if model.isCleaning {
                        ProgressView().controlSize(.small).padding(.horizontal, 30)
                    } else {
                        Label(cleanTitle, systemImage: "wand.and.sparkles")
                            .padding(.horizontal, 4)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.pendingCleanCount == 0 || model.isCleaning || model.isScanning)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var cleanTitle: String {
        let count = model.pendingCleanCount
        return count <= 1 ? "Clean" : "Clean \(count) Files"
    }

    @ViewBuilder private var summary: some View {
        if let summary = model.lastSummary, !model.isCleaning {
            HStack(spacing: 8) {
                Text(summaryText(summary))
                    .font(.callout)
                    .foregroundStyle(summary.failed > 0 ? .orange : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                if let folder = summary.folder {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func summaryText(_ summary: AppModel.CleanSummary) -> String {
        var text = "Cleaned \(summary.files) · \(summary.removed) removed"
        if summary.failed > 0 { text += " · \(summary.failed) failed" }
        return text
    }
}

struct OptionsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleaning Options").font(.headline)
            option("Remove extended attributes", "Download source, quarantine flag, Finder tags and comments.",
                   $model.options.removeExtendedAttributes)
            option("Keep color profile", "Images keep their exact colors. The profile holds no personal data.",
                   $model.options.keepColorProfile)
            option("Keep orientation", "Photos stay the right way up.", $model.options.keepOrientation)
            option("Keep original file dates", "Otherwise the cleaned file is dated now.", $model.options.preserveFileDates)
        }
        .padding(18)
        .frame(width: 320)
    }

    private func option(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
