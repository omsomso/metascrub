import AppKit
import MetaScrubCore
import SwiftUI

/// Development aid: `METASCRUB_SNAPSHOT=<folder> METASCRUB_FILES=<a:b:c>` opens the files, saves PNGs of the
/// main screens into the folder and quits. Cleaning writes copies into `<folder>/cleaned`; originals are untouched.
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["METASCRUB_SNAPSHOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        let files = (environment["METASCRUB_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let savedMode = model.destinationMode, savedFolder = model.outputFolder
            try? await Task.sleep(for: .seconds(1))
            capture(folder.appendingPathComponent("1-cleaner-empty.png"))
            model.selection = .viewerHome
            try? await Task.sleep(for: .milliseconds(500))
            capture(folder.appendingPathComponent("2-viewer-empty.png"))

            model.addToCleaner(files)
            model.selection = .cleaner
            while model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(600))
            capture(folder.appendingPathComponent("3-cleaner-ready.png"))

            for (index, file) in files.prefix(4).enumerated() {
                model.openInViewer([file])
                while model.viewerFiles.contains(where: \.isLoading) { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(900))
                capture(folder.appendingPathComponent("4-viewer-\(index + 1).png"))
            }
            if let file = model.viewerFiles.first, let report = file.report,
               let section = report.sections.first(where: { $0.kind == .embedded && $0.entries.contains(where: \.isEditable) }),
               let entry = section.entries.first(where: \.isEditable) {
                model.selection = .file(file.id)
                model.setValue(file.id, section.id, entry, entry.value + " (edited)")
                if let other = section.entries.first(where: { $0.isRemovable && $0.key != entry.key }) { model.remove(file.id, section.id, other) }
                if let template = section.templates.first { model.addField(file.id, section.id, key: template.key, label: template.label) }
                try? await Task.sleep(for: .milliseconds(800))
                capture(folder.appendingPathComponent("5-viewer-editing.png"))
                model.revert(file.id)
            }

            let output = folder.appendingPathComponent("cleaned", isDirectory: true)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            model.destinationMode = .folder
            model.outputFolder = output
            model.selection = .cleaner
            await model.clean()
            try? await Task.sleep(for: .milliseconds(700))
            capture(folder.appendingPathComponent("6-cleaner-done.png"))
            model.destinationMode = savedMode
            model.outputFolder = savedFolder
            NSApp.terminate(nil)
        }
    }

    @MainActor static func capture(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // The real on-screen pixels when allowed (glass included), else AppKit's own rendering.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return }
        guard let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
    }
}
