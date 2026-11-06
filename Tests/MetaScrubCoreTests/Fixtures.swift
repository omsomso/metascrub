import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MetaScrubCore

/// Builds small sample files carrying known metadata.
enum Fixtures {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MetaScrubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func picture(width: Int = 64, height: Int = 48) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    static let imageProperties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 46.2, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 6.15, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "X1",
                                         kCGImagePropertyTIFFArtist: "Jane Doe"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
                                         kCGImagePropertyExifUserComment: "secret comment"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["holiday", "home"]],
        kCGImagePropertyOrientation: 6,
    ]

    static func image(_ type: UTType, in folder: URL, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture(), imageProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MetadataError.writeFailed("fixture") }
        return url
    }

    /// A PNG with an extra tEXt chunk inserted after IHDR.
    static func png(in folder: URL) throws -> URL {
        let url = try image(.png, in: folder, name: "sample.png")
        var data = try Data(contentsOf: url)
        let text = PNGScrubber.chunk("tEXt", Data("Author\u{0}Jane Doe".utf8))
        data.insert(contentsOf: text, at: 8 + 25)
        try data.write(to: url)
        return url
    }

    /// A two-frame GIF with a comment extension.
    static func gif(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("sample.gif")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, picture(width: 16, height: 16),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw MetadataError.writeFailed("fixture") }
        var data = try Data(contentsOf: url)
        var offset = 13
        let packed = data[10]
        if packed & 0x80 != 0 { offset += 3 << (Int(packed & 0x07) + 1) }
        let comment = Data([0x21, 0xFE, 14]) + Data("secret comment".utf8) + Data([0])
        data.insert(contentsOf: comment, at: offset)
        try data.write(to: url)
        return url
    }

    /// A structurally valid WebP container (the bitstream is a placeholder) with EXIF and XMP chunks.
    static func webpContainer() -> Data {
        func chunk(_ id: String, _ payload: Data) -> Data {
            var writer = ByteWriter()
            writer.ascii(id)
            writer.u32le(payload.count)
            writer.append(payload)
            if payload.count & 1 == 1 { writer.u8(0) }
            return writer.data
        }
        let vp8x = chunk("VP8X", Data([0x2C, 0, 0, 0, 15, 0, 0, 15, 0, 0]))
        let body = vp8x + chunk("ICCP", Data(repeating: 1, count: 8)) + chunk("VP8L", Data(repeating: 7, count: 11))
            + chunk("EXIF", Data("MM\u{0}*secret".utf8)) + chunk("XMP ", Data("<x:xmpmeta>secret</x:xmpmeta>".utf8))
        var writer = ByteWriter()
        writer.ascii("RIFF")
        writer.u32le(4 + body.count)
        writer.ascii("WEBP")
        writer.append(body)
        return writer.data
    }

    // MARK: Audio

    /// Fake MPEG audio frames: enough bytes for the tag parsers; not playable.
    static let mpegFrames = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 413)

    static func mp3(in folder: URL) throws -> URL {
        var tag = ID3.Tag(version: 3, frames: [], size: 0)
        tag.frames.append(ID3.textFrame("TIT2", "Original Title", version: 3))
        tag.frames.append(ID3.textFrame("TPE1", "Jane Doe", version: 3))
        tag.frames.append(ID3.textFrame("COMM", "Recorded at home", version: 3))
        tag.frames.append(ID3.textFrame("TXXX:Studio", "Basement", version: 3))
        let picture = Data([0]) + Data("image/png".utf8) + Data([0, 3, 0]) + Data(repeating: 9, count: 32)
        tag.frames.append(ID3.Frame(id: "APIC", flags: 0, body: picture, opaque: false))
        var v1 = ID3.V1()
        v1.title = "Original Title"
        v1.artist = "Jane Doe"
        let data = ID3.build(tag, padding: 64) + mpegFrames + mpegFrames + ID3.buildV1(v1)
        let url = folder.appendingPathComponent("sample.mp3")
        try data.write(to: url)
        return url
    }

    static func flac(in folder: URL) throws -> URL {
        var info = ByteWriter()
        info.u16be(4096)
        info.u16be(4096)
        info.u24be(0)
        info.u24be(0)
        // 44100 Hz, 2 channels, 16 bits, 44100 samples.
        info.u8(44100 >> 12)
        info.u8((44100 >> 4) & 0xFF)
        info.u8(((44100 & 0x0F) << 4) | (1 << 1) | 0)
        info.u8((15 << 4) | 0)
        info.u32be(44100)
        info.zeros(16)
        let comments = FLACHandler.buildComments(FLACHandler.Comments(vendor: "reference libFLAC 1.4.3",
                                                                      fields: [("TITLE", "Original Title"), ("ARTIST", "Jane Doe"), ("ARTIST", "John Roe")]))
        var picture = ByteWriter()
        picture.u32be(3)
        picture.u32be(9)
        picture.ascii("image/png")
        picture.u32be(0)
        picture.u32be(1)
        picture.u32be(1)
        picture.u32be(24)
        picture.u32be(0)
        picture.u32be(4)
        picture.append(Data([1, 2, 3, 4]))
        var writer = ByteWriter()
        writer.ascii("fLaC")
        for (index, block) in [(0, info.data), (4, comments), (6, picture.data)].enumerated() {
            writer.u8(block.0 | (index == 2 ? 0x80 : 0))
            writer.u24be(block.1.count)
            writer.append(block.1)
        }
        writer.append(Data([0xFF, 0xF8]) + Data(repeating: 0x33, count: 200))
        let url = folder.appendingPathComponent("sample.flac")
        try writer.data.write(to: url)
        return url
    }

    static func wav(in folder: URL) throws -> URL {
        var info = ByteWriter()
        info.ascii("INFO")
        for (id, text) in [("INAM", "Original Title"), ("IART", "Jane Doe"), ("ISFT", "Recorder 2.0")] {
            let value = Data(text.utf8) + Data([0])
            info.ascii(id)
            info.u32le(value.count)
            info.append(value)
            if value.count & 1 == 1 { info.u8(0) }
        }
        var format = ByteWriter()
        format.u16le(1)
        format.u16le(1)
        format.u32le(8000)
        format.u32le(16000)
        format.u16le(2)
        format.u16le(16)
        var bext = ByteWriter()
        bext.append(Data("A field recording".utf8))
        bext.zeros(256 - 17)
        bext.append(Data("Jane's recorder".utf8))
        bext.zeros(602 - 256 - 15)
        let samples = Data(repeating: 0, count: 16000)
        var body = ByteWriter()
        for (id, payload) in [("fmt ", format.data), ("LIST", info.data), ("bext", bext.data), ("data", samples)] {
            body.ascii(id)
            body.u32le(payload.count)
            body.append(payload)
            if payload.count & 1 == 1 { body.u8(0) }
        }
        var writer = ByteWriter()
        writer.ascii("RIFF")
        writer.u32le(4 + body.data.count)
        writer.ascii("WAVE")
        writer.append(body.data)
        let url = folder.appendingPathComponent("sample.wav")
        try writer.data.write(to: url)
        return url
    }

    static func aiff(in folder: URL) throws -> URL {
        var common = ByteWriter()
        common.u16be(1)
        common.u32be(8000)
        common.u16be(16)
        common.append(Data([0x40, 0x0B, 0xFA, 0, 0, 0, 0, 0, 0, 0]))  // 8000 Hz as 80-bit float
        var sound = ByteWriter()
        sound.u32be(0)
        sound.u32be(0)
        sound.zeros(16000)
        var body = ByteWriter()
        for (id, payload) in [("COMM", common.data), ("NAME", Data("Original Title".utf8)), ("AUTH", Data("Jane Doe".utf8)),
                              ("ANNO", Data("take 3".utf8)), ("SSND", sound.data)] {
            body.ascii(id)
            body.u32be(payload.count)
            body.append(payload)
            if payload.count & 1 == 1 { body.u8(0) }
        }
        var writer = ByteWriter()
        writer.ascii("FORM")
        writer.u32be(4 + body.data.count)
        writer.ascii("AIFF")
        writer.append(body.data)
        let url = folder.appendingPathComponent("sample.aiff")
        try writer.data.write(to: url)
        return url
    }

    static func m4a(in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("sample.m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        writer.metadata = [item(.iTunesMetadataSongName, "Original Title"), item(.iTunesMetadataArtist, "Jane Doe"),
                           item(.iTunesMetadataUserComment, "secret comment")]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                      mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        for index in 0..<10 {
            let frames = 4410
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: frames * 2,
                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 2)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                                 sampleCount: frames,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(index * frames), timescale: 44100),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            input.append(sample!)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MetadataError.writeFailed("fixture") }
        return url
    }

    /// A short QuickTime movie with an iPhone-style location and device make.
    static func mov(in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("sample.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func item(_ key: String, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: "mdta/\(key)")
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [item("com.apple.quicktime.location.ISO6709", "+46.2044+006.1432+375.000/"),
                           item("com.apple.quicktime.make", "Apple"), item("com.apple.quicktime.model", "iPhone 99")]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64,
                                                                           AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 20), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MetadataError.writeFailed("fixture") }
        return url
    }

    // MARK: Documents

    static func pdf(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Original Title", kCGPDFContextAuthor: "Jane Doe",
                                                                kCGPDFContextCreator: "Secret App"] as CFDictionary)!
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator><rdf:Seq><rdf:li>Secret Person</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """
        context.addDocumentMetadata(Data(xmp.utf8) as CFData)
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 20, y: 20, width: 80, height: 80))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func docx(in folder: URL) throws -> URL {
        let source = folder.appendingPathComponent("docx-src")
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" Target="docProps/thumbnail.jpeg"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>
            """,
            "docProps/core.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Original Title</dc:title><dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>John Roe</cp:lastModifiedBy><cp:revision>7</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">2024-01-02T03:04:05Z</dcterms:created></cp:coreProperties>
            """,
            "docProps/app.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Template>Normal.dotm</Template><TotalTime>42</TotalTime><Pages>1</Pages><Words>3</Words><Application>Microsoft Office Word</Application><Company>Acme Secret Corp</Company></Properties>
            """,
            "docProps/custom.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Client"><vt:lpwstr>Big Client</vt:lpwstr></property></Properties>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello there world</w:t></w:r></w:p></w:body></w:document>
            """,
        ]
        for (path, contents) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let thumbnail = source.appendingPathComponent("docProps/thumbnail.jpeg")
        let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture(), nil)
        CGImageDestinationFinalize(destination)
        let url = folder.appendingPathComponent("sample.docx")
        try run("/usr/bin/zip", ["-q", "-r", url.path, "[Content_Types].xml", "_rels", "docProps", "word"], in: source)
        return url
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    static func setDownloadAttributes(_ url: URL) throws {
        let whereFroms = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/secret/file", "https://example.com/"],
                                                            format: .binary, options: 0)
        FileSystemMetadata.setAttribute("com.apple.metadata:kMDItemWhereFroms", whereFroms, on: url)
        FileSystemMetadata.setAttribute("com.apple.quarantine", Data("0083;65a1b2c3;Safari;".utf8), on: url)
    }
}

extension MetadataReport {
    func entry(_ key: String) -> MetadataEntry? {
        sections.flatMap(\.entries).first { $0.key == key }
    }

    func value(_ key: String) -> String? { entry(key)?.value }

    func section(_ id: String) -> MetadataSection? { sections.first { $0.id == id } }
}
