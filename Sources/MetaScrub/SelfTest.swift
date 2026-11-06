import CoreGraphics
import Foundation
import ImageIO
import MetaScrubCore
import UniformTypeIdentifiers

/// `MetaScrub --self-test FOLDER`: makes a photo and a PDF carrying personal metadata in FOLDER, then
/// checks that the built app reads, cleans and edits them without touching the content. Used by
/// omso Builder after building; it opens no window and touches nothing outside FOLDER.
enum SelfTest {
    static func run(in folder: URL) async -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
            if !condition { failures.append(message) }
        }
        do {
            try? FileManager.default.removeItem(at: folder)
            let output = folder.appendingPathComponent("cleaned", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            print("Photo (JPEG with location, camera and author)")
            let photo = try makePhoto(in: folder)
            let before = await MetadataEngine.inspect(photo, includeSpotlight: false)
            check(before.location != nil, "location is found")
            check(Set(before.highlights).isSuperset(of: [.location, .device, .people]), "location, device and people are flagged")
            let cleaned = try await MetadataEngine.clean(photo, options: CleanOptions(), destination: .folder(output))
            let after = await MetadataEngine.inspect(cleaned.output, includeSpotlight: false)
            check(after.location == nil && after.embeddedEntries.isEmpty, "cleaned copy has no personal metadata")
            check(orientation(cleaned.output) == 6, "orientation is kept")
            check(pixels(photo) != nil && pixels(photo) == pixels(cleaned.output), "pixels are unchanged")
            check(before.embeddedEntries.count > 0 && cleaned.removedCount >= before.embeddedEntries.count, "removed \(cleaned.removedCount) fields")
            check(!after.embeddedEntries.contains { $0.key == "tiff:Make" }, "camera make is gone")
            try await MetadataEngine.save([.set("img.description", "dc:title", "Self-test")], for: cleaned.output)
            let edited = await MetadataEngine.inspect(cleaned.output, includeSpotlight: false)
            check(edited.embeddedEntries.first { $0.key == "dc:title" }?.value == "Self-test", "an edited title is saved")
            check(pixels(photo) == pixels(cleaned.output), "pixels are unchanged after editing")

            print("PDF (author, creator tool)")
            let pdf = try makePDF(in: folder)
            let pdfBefore = await MetadataEngine.inspect(pdf, includeSpotlight: false)
            check(pdfBefore.embeddedEntries.first { $0.key == "Author" }?.value == "Self Test Author", "author is found")
            let pdfCleaned = try await MetadataEngine.clean(pdf, options: CleanOptions(), destination: .folder(output))
            check(pdfCleaned.remaining.isEmpty, "cleaned PDF has no document info left")
            check((try? Data(contentsOf: pdfCleaned.output))?.range(of: Data("Self Test Author".utf8)) == nil, "author name is gone from the bytes")
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        print(failures.isEmpty ? "Self-test passed." : "Self-test failed: \(failures.count) check(s).")
        return failures.isEmpty ? 0 : 1
    }

    private static func makePhoto(in folder: URL) throws -> URL {
        let context = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 30, y: 16, width: 32, height: 32))
        let url = folder.appendingPathComponent("photo.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MetadataError.writeFailed("Could not create the test photo.")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 46.2, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 6.15, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFArtist: "Self Test Author"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyOrientation: 6,
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MetadataError.writeFailed("Could not write the test photo.") }
        return url
    }

    private static func makePDF(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("document.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Self-test", kCGPDFContextAuthor: "Self Test Author",
                                                                       kCGPDFContextCreator: "Self Test Tool"] as CFDictionary) else {
            throw MetadataError.writeFailed("Could not create the test PDF.")
        }
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func orientation(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return properties[kCGImagePropertyOrientation as String] as? Int
    }

    private static func pixels(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.dataProvider?.data as Data?
    }
}
