import Foundation
import MetaScrubCore

/// `MetaScrub --inspect FILE…` prints what the viewer shows; `--clean` writes cleaned copies.
enum CommandLineTool {
    static let usage = """
    Usage: MetaScrub                                   open the app
           MetaScrub --inspect FILE…                   print every metadata field
           MetaScrub --clean FILE… --out FOLDER        save cleaned copies into FOLDER
           MetaScrub --clean FILE… --in-place          replace the originals
           MetaScrub --self-test FOLDER                check the build on generated files in FOLDER
    Clean options: --keep-attributes  --drop-color-profile  --drop-orientation  --keep-dates
    """

    static func run(_ arguments: [String]) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status: Int32 = 0 }
        let box = Box()
        Task.detached {
            box.status = await perform(arguments)
            done.signal()
        }
        done.wait()
        return box.status
    }

    private static func perform(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first, command != "--help" else {
            print(usage)
            return 0
        }
        if command == "--self-test" {
            guard arguments.count == 2 else { print(usage); return 64 }
            return await SelfTest.run(in: URL(fileURLWithPath: arguments[1], isDirectory: true))
        }
        var files: [URL] = []
        var output: URL?
        var inPlace = false
        var options = CleanOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                index += 1
                guard index < arguments.count else { print(usage); return 64 }
                output = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--in-place": inPlace = true
            case "--keep-attributes": options.removeExtendedAttributes = false
            case "--drop-color-profile": options.keepColorProfile = false
            case "--drop-orientation": options.keepOrientation = false
            case "--keep-dates": options.preserveFileDates = true
            default: files.append(URL(fileURLWithPath: arguments[index]))
            }
            index += 1
        }
        guard !files.isEmpty else { print(usage); return 64 }

        if command == "--inspect" {
            for file in files { print(describe(await MetadataEngine.inspect(file))) }
            return 0
        }
        guard inPlace || output != nil else {
            print("Choose --out FOLDER or --in-place.")
            return 64
        }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var status: Int32 = 0
        for file in files {
            do {
                let result = try await MetadataEngine.clean(file, options: options, destination: output.map { .folder($0) } ?? .overwrite)
                var line = "✓ \(file.lastPathComponent) → \(result.output.path): removed \(result.removedCount)"
                if !result.remaining.isEmpty { line += ", kept \(result.remaining.map(\.label).joined(separator: ", "))" }
                print(line)
                for note in result.notes { print("  · \(note)") }
            } catch {
                print("✗ \(file.lastPathComponent): \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }

    static func describe(_ report: MetadataReport) -> String {
        var lines = ["== \(report.url.path)", "\(report.format)" + (report.facts.isEmpty ? "" : " · " + report.facts.map(\.value).joined(separator: " · "))]
        if !report.highlights.isEmpty { lines.append("Contains: " + report.highlights.map(\.title).joined(separator: ", ")) }
        if let location = report.location { lines.append(String(format: "Location: %.5f, %.5f", location.latitude, location.longitude)) }
        lines.append("Can edit: \(report.canEdit ? "yes" : "no") · Can clean: \(report.canClean ? "yes" : "no")")
        for note in report.notes { lines.append("Note: \(note)") }
        for section in report.sections where !section.entries.isEmpty {
            lines.append("")
            lines.append("[\(section.title)] (\(section.kind.rawValue))")
            for entry in section.entries {
                let value = entry.value.replacingOccurrences(of: "\n", with: " ⏎ ")
                lines.append("  \(entry.label): \(value.count > 140 ? String(value.prefix(140)) + "…" : value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
