import Foundation
import ImageIO
import PDFKit
import Testing
@testable import MetaScrubCore

/// End-to-end checks per format: read the sample's metadata, clean it, and edit it.
@Suite struct ImageTests {
    @Test func jpegReadsCameraLocationAndPeople() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.jpeg, in: folder, name: "photo.jpg")
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("tiff:Make") == "TestCam")
        #expect(report.location != nil)
        #expect(abs((report.location?.latitude ?? 0) - 46.2) < 0.001)
        #expect(Set(report.highlights).isSuperset(of: [.location, .device, .people]))
        #expect(report.canEdit && report.canClean)
    }

    @Test func jpegCleanKeepsPixelsAndOrientation() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.jpeg, in: folder, name: "photo.jpg")
        let output = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .folder(output))
        #expect(result.output.deletingLastPathComponent().lastPathComponent == "out")
        #expect(result.remaining.isEmpty)  // orientation stays, but counts as technical
        #expect(result.removedCount > 5)
        let source = try #require(CGImageSourceCreateWithURL(result.output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties["{GPS}"] == nil && properties["{IPTC}"] == nil)
        #expect(properties["Orientation"] as? Int == 6)
        #expect(properties["PixelWidth"] as? Int == 64)
        // The scan data is copied byte for byte.
        let original = try Data(contentsOf: url), cleaned = try Data(contentsOf: result.output)
        let scan = { (data: Data) in data.range(of: Data([0xFF, 0xDA])).map { data[$0.lowerBound...] } }
        #expect(scan(original) == scan(cleaned))
    }

    @Test func jpegCleanWithoutOrientationRemovesEverything() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.jpeg, in: folder, name: "photo.jpg")
        let result = try await MetadataEngine.clean(url, options: CleanOptions(keepOrientation: false), destination: .overwrite)
        #expect(result.output == url)
        #expect(result.remaining.isEmpty)
    }

    @Test func jpegEditSetsRemovesAndAdds() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.jpeg, in: folder, name: "photo.jpg")
        try await MetadataEngine.save([
            .set("img.camera", "tiff:Make", "OtherCam"),
            .remove("img.camera", "tiff:Model"),
            .set("img.description", "dc:title", "Sunset"),
            .set("img.description", "dc:subject", "beach; evening"),
        ], for: url)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("tiff:Make") == "OtherCam")
        #expect(report.entry("tiff:Model") == nil)
        #expect(report.value("dc:title") == "Sunset")
        #expect(report.value("dc:subject") == "beach; evening")
        #expect(report.value("exif:UserComment") == "secret comment")  // untouched fields survive
    }

    @Test func pngCleanDropsTextAndKeepsImage() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.png(in: folder)
        let before = await MetadataEngine.inspect(url)
        #expect(before.section("img.pngtext")?.entries.contains { $0.value == "Jane Doe" } == true)
        let result = try await MetadataEngine.clean(url, options: CleanOptions(keepOrientation: false), destination: .overwrite)
        #expect(result.remaining.isEmpty)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 64)
        #expect(try Data(contentsOf: url).range(of: Data("Jane".utf8)) == nil)
    }

    @Test func pngEditRewritesLosslessly() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.png, in: folder, name: "sample.png")
        try await MetadataEngine.save([.set("img.description", "dc:title", "New PNG title"), .remove("img.camera", "tiff:Make")], for: url)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("dc:title") == "New PNG title")
        #expect(report.entry("tiff:Make") == nil)
    }

    @Test func heicCleanBlanksExifWithoutReencoding() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.heic, in: folder, name: "photo.heic")
        let size = try Data(contentsOf: url).count
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.notes.isEmpty, "expected the lossless path: \(result.notes)")
        #expect(try Data(contentsOf: url).count == size)
        #expect(!result.remaining.contains { ["tiff:Make", "tiff:Artist", "exif:GPSLatitude", "exif:UserComment"].contains($0.key) })
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties["{GPS}"] == nil)
        #expect(properties["Orientation"] as? Int == 6)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 64)
    }

    @Test func heicEditChangesFields() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.heic, in: folder, name: "photo.heic")
        try await MetadataEngine.save([.set("img.camera", "tiff:Make", "OtherCam")], for: url)
        #expect(await MetadataEngine.inspect(url).value("tiff:Make") == "OtherCam")
    }

    @Test func tiffCleanRemovesTags() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.image(.tiff, in: folder, name: "scan.tiff")
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(!result.remaining.contains { ["tiff:Make", "tiff:Artist", "exif:GPSLatitude"].contains($0.key) })
        #expect(ImageHandler.orientation(of: url) == 6)
    }

    @Test func gifCleanDropsCommentAndKeepsFrames() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.gif(in: folder)
        #expect(try Data(contentsOf: url).range(of: Data("secret comment".utf8)) != nil)
        _ = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("secret comment".utf8)) == nil)
        #expect(data.range(of: Data("NETSCAPE2.0".utf8)) != nil)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func webpCleanDropsExifAndXmpChunks() throws {
        let cleaned = try WebPScrubber.clean(Fixtures.webpContainer(), keepICC: true)
        #expect(cleaned.range(of: Data("secret".utf8)) == nil)
        #expect(cleaned.range(of: Data("ICCP".utf8)) != nil)
        #expect(cleaned.u32le(4) == cleaned.count - 8)
        #expect(cleaned[cleaned.startIndex + 20] == 0x20)  // VP8X flags: only ICC left
        let withoutProfile = try WebPScrubber.clean(Fixtures.webpContainer(), keepICC: false)
        #expect(withoutProfile.range(of: Data("ICCP".utf8)) == nil)
        #expect(withoutProfile[withoutProfile.startIndex + 20] == 0)
    }
}

@Suite struct AudioTests {
    @Test func mp3ReadsTags() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.mp3(in: folder)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("TIT2") == "Original Title")
        #expect(report.value("TPE1") == "Jane Doe")
        #expect(report.value("COMM") == "Recorded at home")
        #expect(report.value("TXXX:Studio") == "Basement")
        #expect(report.entry("APIC")?.image?.count == 32)
        #expect(report.value("v1:artist") == "Jane Doe")
    }

    @Test func mp3EditRewritesTags() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.mp3(in: folder)
        try await MetadataEngine.save([
            .set("id3v2", "TIT2", "Nouveau titre é"), .remove("id3v2", "COMM"), .set("id3v2", "TALB", "An Album"),
            .set("id3v2", "Mood", "calm"), .set("id3v1", "v1:title", "V1 Title"), .set("id3v2", "TXXX:Studio", "Attic"),
        ], for: url)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("TIT2") == "Nouveau titre é")
        #expect(report.entry("COMM") == nil)
        #expect(report.value("TALB") == "An Album")
        #expect(report.value("TXXX:Mood") == "calm")
        #expect(report.value("TXXX:Studio") == "Attic")
        #expect(report.value("v1:title") == "V1 Title")
        #expect(report.entry("APIC")?.image?.count == 32)
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Fixtures.mpegFrames + Fixtures.mpegFrames) != nil)
    }

    @Test func mp3CleanLeavesOnlyAudio() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.mp3(in: folder)
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(try Data(contentsOf: url) == Fixtures.mpegFrames + Fixtures.mpegFrames)
        #expect(result.remaining.isEmpty)
    }

    @Test func flacReadEditAndClean() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.flac(in: folder)
        var report = await MetadataEngine.inspect(url)
        #expect(report.value("TITLE") == "Original Title")
        #expect(report.value("ARTIST#1") == "John Roe")
        #expect(report.section("pictures")?.entries.count == 1)
        #expect(report.facts.contains { $0.value.contains("44.1 kHz") })

        try await MetadataEngine.save([.set("vorbis", "TITLE", "New"), .remove("vorbis", "ARTIST#1"), .set("vorbis", "mood", "calm"),
                                       .remove("pictures", "block2")], for: url)
        report = await MetadataEngine.inspect(url)
        #expect(report.value("TITLE") == "New")
        #expect(report.entry("ARTIST#1") == nil)
        #expect(report.value("ARTIST") == "Jane Doe")
        #expect(report.value("MOOD") == "calm")
        #expect(report.section("pictures") == nil)

        _ = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        let layout = try FLACHandler.layout(try Data(contentsOf: url))
        #expect(layout.blocks.map(\.type) == [0])
        #expect(try Data(contentsOf: url).suffix(202) == Data([0xFF, 0xF8]) + Data(repeating: 0x33, count: 200))
    }

    @Test func wavReadEditAndClean() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.wav(in: folder)
        var report = await MetadataEngine.inspect(url)
        #expect(report.value("IART") == "Jane Doe")
        #expect(report.value("bext:originator") == "Jane's recorder")
        #expect(report.facts.contains { $0.label == "Duration" })

        try await MetadataEngine.save([.set("info", "INAM", "Renamed"), .remove("info", "ISFT"), .set("info", "ICMT", "note")], for: url)
        report = await MetadataEngine.inspect(url)
        #expect(report.value("INAM") == "Renamed")
        #expect(report.entry("ISFT") == nil)
        #expect(report.value("ICMT") == "note")
        #expect(report.value("bext:originator") == "Jane's recorder")

        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.remaining.isEmpty)
        let data = try Data(contentsOf: url)
        let expectedSize = 12 + 8 + 16 + 8 + 16000  // header, fmt chunk, data chunk
        #expect(data.count == expectedSize)
        #expect(await MetadataEngine.inspect(url).facts.contains { $0.label == "Duration" })
    }

    @Test func aiffReadEditAndClean() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.aiff(in: folder)
        var report = await MetadataEngine.inspect(url)
        #expect(report.value("AUTH") == "Jane Doe")
        try await MetadataEngine.save([.set("text", "NAME", "Renamed"), .remove("text", "AUTH"), .set("text", "(c) ", "2026 Me")], for: url)
        report = await MetadataEngine.inspect(url)
        #expect(report.value("NAME") == "Renamed")
        #expect(report.entry("AUTH") == nil)
        #expect(report.value("(c) ") == "2026 Me")
        #expect(report.value("ANNO") == "take 3")
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.remaining.isEmpty)
        #expect(await MetadataEngine.inspect(url).facts.contains { $0.label == "Duration" })
    }

    @Test func m4aReadEditAndClean() async throws {
        let folder = try Fixtures.folder()
        let url = try await Fixtures.m4a(in: folder)
        var report = await MetadataEngine.inspect(url)
        #expect(report.value("itsk/%A9ART") == "Jane Doe")
        try await MetadataEngine.save([.set("av.itsk", "itsk/%A9nam", "New Title"), .remove("av.itsk", "itsk/%A9cmt"),
                                       .set("av.itsk", "itsk/%A9alb", "Album")], for: url)
        report = await MetadataEngine.inspect(url)
        #expect(report.value("itsk/%A9nam") == "New Title")
        #expect(report.entry("itsk/%A9cmt") == nil)
        #expect(report.value("itsk/%A9alb") == "Album")
        #expect(report.value("itsk/%A9ART") == "Jane Doe")
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(!result.remaining.contains { $0.key.hasPrefix("itsk/") })
        #expect(await MetadataEngine.inspect(url).facts.contains { $0.label == "Duration" })
    }

    @Test func movLocationIsFoundAndCleaned() async throws {
        let folder = try Fixtures.folder()
        let url = try await Fixtures.mov(in: folder)
        let report = await MetadataEngine.inspect(url)
        #expect(report.location != nil)
        #expect(abs((report.location?.longitude ?? 0) - 6.1432) < 0.0001)
        #expect(report.highlights.contains(.location))
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.remaining.isEmpty, "\(result.remaining.map(\.key))")
        #expect(await MetadataEngine.inspect(url).facts.contains { $0.label == "Video" })
    }
}

@Suite struct DocumentTests {
    @Test func pdfReadShowsInfoAndXMP() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.pdf(in: folder)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("Author") == "Jane Doe")
        #expect(report.value("Creator") == "Secret App")
        #expect(report.entry("xmp") != nil)
        #expect(report.sections.flatMap(\.entries).contains { $0.value == "Secret Person" })
    }

    @Test func pdfCleanRemovesInfoXMPAndProducer() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.pdf(in: folder)
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        let info = PDFHandler.infoDictionary(document.documentRef!)
        #expect(info["Author"] == nil && info["Title"] == nil && info["Creator"] == nil)
        #expect(info["Producer"] == nil && info["CreationDate"] == nil && info["ModDate"] == nil)
        #expect(result.remaining.isEmpty, "\(result.remaining.map(\.key))")
        #expect(PDFHandler.xmpPacket(document.documentRef!) == nil)
        #expect(!result.remaining.contains { $0.value.contains("Secret") || $0.value.contains("Jane") || $0.value.contains("macOS") })
    }

    @Test func pdfEditKeepsProducerAndChangesTitle() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.pdf(in: folder)
        try await MetadataEngine.save([.set("pdf.info", "Title", "New Title"), .remove("pdf.info", "Author"),
                                       .set("pdf.info", "Producer", "My Tool"), .remove("pdf.xmp", "xmp")], for: url)
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("Title") == "New Title")
        #expect(report.entry("Author") == nil)
        #expect(report.value("Producer") == "My Tool")
        #expect(report.entry("xmp") == nil)
    }

    @Test func docxReadEditAndClean() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.docx(in: folder)
        var report = await MetadataEngine.inspect(url)
        #expect(report.value("dc:creator") == "Jane Doe")
        #expect(report.value("Company") == "Acme Secret Corp")
        #expect(report.value("custom:Client") == "Big Client")
        #expect(report.section("office.thumbnail") != nil)

        try await MetadataEngine.save([.set("office.core", "dc:title", "New Title"), .remove("office.core", "cp:lastModifiedBy"),
                                       .set("office.core", "dc:subject", "Added"), .set("office.app", "Company", "Other Corp"),
                                       .set("office.custom", "Project", "Apollo")], for: url)
        report = await MetadataEngine.inspect(url)
        #expect(report.value("dc:title") == "New Title")
        #expect(report.entry("cp:lastModifiedBy") == nil)
        #expect(report.value("dc:subject") == "Added")
        #expect(report.value("Company") == "Other Corp")
        #expect(report.value("custom:Project") == "Apollo")
        #expect(try Fixtures.run("/usr/bin/unzip", ["-tq", url.path]).0 == 0)

        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(try Fixtures.run("/usr/bin/unzip", ["-tq", url.path]).0 == 0)
        report = await MetadataEngine.inspect(url)
        #expect(report.section("office.core")?.entries.isEmpty == true)
        #expect(report.entry("Company") == nil && report.entry("Template") == nil)
        #expect(report.value("Pages") == "1")
        #expect(report.section("office.thumbnail") == nil)
        #expect(report.section("office.zip") == nil)
        #expect(result.removedCount >= 8)
        let archive = try ZipArchive(try Data(contentsOf: url))
        #expect(try archive.contents("word/document.xml").map { String(decoding: $0, as: UTF8.self).contains("Hello there world") } == true)
        #expect(try archive.contents("_rels/.rels").map { String(decoding: $0, as: UTF8.self).contains("thumbnail") } == false)
    }
}

@Suite struct FileSystemTests {
    @Test func extendedAttributesAreShownAndRemoved() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.mp3(in: folder)
        try Fixtures.setDownloadAttributes(url)
        let report = await MetadataEngine.inspect(url)
        let whereFrom = try #require(report.entry("com.apple.metadata:kMDItemWhereFroms"))
        #expect(whereFrom.value.contains("https://example.com/secret/file"))
        #expect(report.value("com.apple.quarantine")?.contains("Safari") == true)
        #expect(report.highlights.contains(.history))

        let kept = try await MetadataEngine.clean(url, options: CleanOptions(removeExtendedAttributes: false), destination: .folder(folder))
        #expect(FileSystemMetadata.attributeNames(kept.output).contains("com.apple.metadata:kMDItemWhereFroms"))
        #expect(kept.output.lastPathComponent == "sample 2.mp3")

        _ = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        let names = FileSystemMetadata.attributeNames(url)
        #expect(!names.contains("com.apple.metadata:kMDItemWhereFroms") && !names.contains("com.apple.quarantine"))
    }

    @Test func viewerRemovesOneAttributeAndEditsDates() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appendingPathComponent("notes.bin")
        try Data([1, 2, 3]).write(to: url)
        try Fixtures.setDownloadAttributes(url)
        try await MetadataEngine.save([.remove(FileSystemMetadata.attributesSectionID, "com.apple.quarantine"),
                                       .set(FileSystemMetadata.fileSectionID, "modified", "2020-02-03 04:05:06")], for: url)
        let names = FileSystemMetadata.attributeNames(url)
        #expect(!names.contains("com.apple.quarantine"))
        #expect(names.contains("com.apple.metadata:kMDItemWhereFroms"))
        #expect(await MetadataEngine.inspect(url).value("modified") == "2020-02-03 04:05:06")
    }

    @Test func unknownFilesStillCleanAttributes() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appendingPathComponent("data.xyz")
        try Data(repeating: 7, count: 100).write(to: url)
        try Fixtures.setDownloadAttributes(url)
        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.removedCount == 2)
        #expect(try Data(contentsOf: url) == Data(repeating: 7, count: 100))
        #expect(!result.notes.isEmpty)
    }

    @Test func savingAsLeavesOriginalAlone() async throws {
        let folder = try Fixtures.folder()
        let url = try Fixtures.mp3(in: folder)
        let copy = folder.appendingPathComponent("copy.mp3")
        try await MetadataEngine.save([.set("id3v2", "TIT2", "Copy Title")], for: url, saveAs: copy)
        #expect(await MetadataEngine.inspect(url).value("TIT2") == "Original Title")
        #expect(await MetadataEngine.inspect(copy).value("TIT2") == "Copy Title")
    }
}
