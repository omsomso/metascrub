import AppKit
import MetaScrubCore
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--inspect", "--clean", "--self-test", "--help"].contains(arguments.first ?? "") {
            exit(CommandLineTool.run(arguments))
        }
        MetaScrubApp.main()
    }
}

struct MetaScrubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("MetaScrub", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear { Snapshot.runIfRequested(model) }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open in Viewer…") { model.chooseFiles(for: .viewer) }
                    .keyboardShortcut("o")
                Button("Add Files to Cleaner…") { model.chooseFiles(for: .cleaner) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { if let id = model.selectedFileID { Task { await model.save(id) } } }
                    .keyboardShortcut("s")
                    .disabled(!selectedHasChanges)
                Button("Save As…") { if let id = model.selectedFileID { model.saveAs(id) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!selectedHasChanges)
                Button("Revert Changes") { if let id = model.selectedFileID { model.revert(id) } }
                    .disabled(!selectedHasChanges)
            }
            CommandGroup(after: .sidebar) {
                Button("Cleaner") { model.selection = .cleaner }
                    .keyboardShortcut("1")
                Button("Viewer") { model.selection = model.viewerFiles.last.map { .file($0.id) } ?? .viewerHome }
                    .keyboardShortcut("2")
                Divider()
            }
        }
    }

    private var selectedHasChanges: Bool {
        guard let id = model.selectedFileID else { return false }
        return model.viewerFiles.first { $0.id == id }?.hasChanges ?? false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with "Open With" go to the viewer.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.openInViewer(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.hasUnsavedChanges else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "You have unsaved metadata changes."
            alert.informativeText = "If you quit now, your edits are discarded. The files themselves are unchanged."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            switch model.selection {
            case .file(let id):
                FileDetailView(fileID: id).id(id)
            case .viewerHome:
                ViewerHome()
            case .cleaner, nil:
                CleanerView()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Clean") {
                Label("Cleaner", systemImage: "wand.and.sparkles")
                    .badge(model.cleanItems.count)
                    .tag(AppModel.Selection.cleaner)
            }
            Section("View & Edit") {
                Label("Open Files…", systemImage: "plus.viewfinder")
                    .tag(AppModel.Selection.viewerHome)
                ForEach(model.viewerFiles) { file in
                    SidebarFileRow(file: file)
                        .tag(AppModel.Selection.file(file.id))
                        .contextMenu {
                            Button("Send to Cleaner") { model.sendToCleaner(file.id) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Divider()
                            Button("Close") { model.closeViewerFile(file.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            model.openInViewer(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(6).allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Drop files here to inspect them")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
    }
}

struct SidebarFileRow: View {
    @Environment(AppModel.self) private var model
    let file: AppModel.ViewerFile

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(url: file.url, size: 18)
            Text(file.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if file.isLoading || file.isSaving {
                ProgressView().controlSize(.mini)
            } else if file.hasChanges {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Unsaved changes")
            } else if let highlight = file.report?.highlights.first {
                Image(systemName: highlight.symbol).font(.caption2).foregroundStyle(highlight.color).help("Contains \(highlight.title.lowercased()) data")
            }
        }
        .help(file.url.path)
    }
}
