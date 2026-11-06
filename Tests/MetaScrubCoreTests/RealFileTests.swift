import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import MetaScrubCore

/// Opt-in smoke test on real files: `METASCRUB_SAMPLES=/folder swift test --filter RealFileTests`.
/// Every file is copied first; the originals are never touched.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["METASCRUB_SAMPLES"] != nil))
struct RealFileTests {
    static var samples: [URL] {
        guard let folder = ProcessInfo.processInfo.environment["METASCRUB_SAMPLES"] else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
    }

    /// Something that changes if the content is damaged: pixels, decoded audio/video length, or PDF text.
    struct Fingerprint: Equatable, CustomStringConvertible {
        var summary: String
        var audioFrames = 0

        /// macOS's MP3 decoder sometimes trims its 529-sample start-up delay and sometimes not, for the same bytes.
        static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
            lhs.summary == rhs.summary && abs(lhs.audioFrames - rhs.audioFrames) <= 1152
        }

        var description: String { audioFrames > 0 ? "\(summary) audio \(audioFrames)" : summary }
    }

    static func fingerprint(_ url: URL) async -> Fingerprint {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let data = image.dataProvider?.data as Data? {
            return Fingerprint(summary: "image \(image.width)x\(image.height) \(data.hashValue)")
        }
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            return Fingerprint(summary: "pdf \(document.pageCount) \(document.string?.hashValue ?? 0)")
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            var fingerprint = Fingerprint(summary: String(format: "media %.3f", duration.seconds))
            if let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                reader.add(output)
                reader.startReading()
                while let buffer = output.copyNextSampleBuffer() { fingerprint.audioFrames += CMSampleBufferGetNumSamples(buffer) }
                if reader.status != .completed { fingerprint.summary += " decode failed" }
            }
            return fingerprint
        }
        return Fingerprint(summary: "bytes \((try? Data(contentsOf: url))?.count ?? 0)")
    }

    @Test(arguments: samples)
    func editThenCleanKeepsContent(_ original: URL) async throws {
        let folder = try Fixtures.folder()
        let url = folder.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: url)
        let before = await Self.fingerprint(url)
        let report = await MetadataEngine.inspect(url)

        if report.canEdit, let section = report.sections.first(where: { $0.kind == .embedded && $0.entries.contains(where: \.isEditable) }),
           let entry = section.entries.first(where: \.isEditable) {
            do {
                try await MetadataEngine.save([.set(section.id, entry.key, entry.value + " (smoke)")], for: url)
            } catch {
                // Some codecs can't go through AVFoundation's pass-through export; that must fail loudly, not damage the file.
                #expect(await Self.fingerprint(url) == before)
                withKnownIssue("Pass-through export doesn't support every codec (e.g. xHE-AAC)") {
                    Issue.record("Editing \(url.lastPathComponent) failed: \(error.localizedDescription)")
                }
                return
            }
            let edited = await MetadataEngine.inspect(url)
            #expect(edited.value(entry.key) == entry.value + " (smoke)", "\(entry.key) in \(url.lastPathComponent)")
            let afterEdit = await Self.fingerprint(url)
            #expect(afterEdit == before, "edit changed the content of \(url.lastPathComponent): \(before) → \(afterEdit)")
        }

        if report.canClean {
            let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
            #expect(result.remaining.isEmpty, "\(url.lastPathComponent) kept \(result.remaining.map(\.key))")
            let afterClean = await Self.fingerprint(url)
            #expect(afterClean == before, "clean changed the content of \(url.lastPathComponent): \(before) → \(afterClean)")
        }
    }
}
