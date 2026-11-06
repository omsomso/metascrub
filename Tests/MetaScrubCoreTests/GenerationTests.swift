import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MetaScrubCore

/// AI image generators' metadata: ComfyUI keeps its node graph in PNG text chunks that ImageIO doesn't
/// report; Automatic1111-style tools write a parameters text (in PNG text or EXIF).
@Suite struct GenerationTests {
    static let prompt: [String: Any] = [
        "3": ["class_type": "KSampler", "inputs": ["seed": 123456, "steps": 25, "cfg": 7.5, "sampler_name": "euler", "scheduler": "normal",
                                                    "denoise": 1, "model": ["10", 0], "positive": ["6", 0], "negative": ["7", 0],
                                                    "latent_image": ["5", 0]] as [String: Any]],
        "4": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": "sdxl_base.safetensors"]],
        "5": ["class_type": "EmptyLatentImage", "inputs": ["width": 1024, "height": 768, "batch_size": 1]],
        "6": ["class_type": "CLIPTextEncode", "inputs": ["text": "a lighthouse at dusk", "clip": ["10", 1]] as [String: Any]],
        "7": ["class_type": "CLIPTextEncode", "inputs": ["text": "blurry", "clip": ["10", 1]] as [String: Any]],
        "10": ["class_type": "LoraLoader", "inputs": ["lora_name": "watercolor.safetensors", "model": ["4", 0]] as [String: Any]],
    ]

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The UI workflow is big in real life; pad it past the in-place editing limit.
    static let workflow = json(["nodes": (1...6).map { ["id": $0, "type": "Node\($0)"] }, "links": [], "version": 0.4,
                                "extra": ["notes": String(repeating: "lorem ipsum ", count: 600)]] as [String: Any])

    static func zlib(_ data: Data) -> Data {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        var out = Data([0x78, 0x9C]) + ((try! (data as NSData).compressed(using: .zlib)) as Data)
        out.append(contentsOf: [UInt8(b >> 8), UInt8(b & 0xFF), UInt8(a >> 8), UInt8(a & 0xFF)])
        return out
    }

    /// A PNG saved the way ComfyUI does it, plus a compressed and a Unicode text chunk.
    static func comfyPNG(in folder: URL) throws -> URL {
        let url = try Fixtures.image(.png, in: folder, name: "ComfyUI_00001_.png")
        var data = try Data(contentsOf: url)
        let chunks = PNGScrubber.chunk("tEXt", Data("prompt\u{0}".utf8) + Data(json(prompt).utf8))
            + PNGScrubber.chunk("tEXt", Data("workflow\u{0}".utf8) + Data(workflow.utf8))
            + PNGScrubber.chunk("zTXt", Data("Comment\u{0}\u{0}".utf8) + zlib(Data("made at home".utf8)))
            + PNGScrubber.chunk("iTXt", Data("Title\u{0}\u{0}\u{0}\u{0}\u{0}".utf8) + Data("Phare ☀︎ au crépuscule".utf8))
        data.insert(contentsOf: chunks, at: 8 + 25)
        try data.write(to: url)
        return url
    }

    @Test func comfyPNGShowsWorkflowAndSummary() async throws {
        let url = try Self.comfyPNG(in: try Fixtures.folder())
        let report = await MetadataEngine.inspect(url)
        let generation = try #require(report.section("img.generation"))
        #expect(Set(generation.entries.map(\.key)) == ["png:prompt", "png:workflow"])
        #expect(generation.entries.allSatisfy { $0.highlight == .generation })
        #expect(report.highlights.contains(.generation))
        #expect(report.entry("png:prompt")?.isEditable == false)  // JSON graphs are read-only
        #expect(report.entry("png:workflow")?.isEditable == false)
        #expect(report.entry("png:prompt")?.isRemovable == true)
        #expect(report.entry("png:workflow")?.isRemovable == true)
        #expect(report.value("png:Comment") == "made at home")
        #expect(report.value("png:Title") == "Phare ☀︎ au crépuscule")

        let summary = try #require(report.section("img.generation.summary"))
        #expect(summary.kind == .derived)
        let fields = Dictionary(summary.entries.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(fields["Generator"] == "ComfyUI")
        #expect(fields["Model"] == "sdxl_base.safetensors")
        #expect(fields["LoRA"] == "watercolor.safetensors")
        #expect(fields["Positive prompt"] == "a lighthouse at dusk")
        #expect(fields["Negative prompt"] == "blurry")
        #expect(fields["Seed"] == "123456")
        #expect(fields["Steps"] == "25")
        #expect(fields["CFG"] == "7.5")
        #expect(fields["Sampler"] == "euler")
        #expect(fields["Size"] == "1024 × 768")
        // The summary is not counted as extra metadata.
        #expect(!report.embeddedEntries.contains { $0.key.hasPrefix("gen:") })
    }

    @Test func editingOtherFieldsKeepsTheWorkflow() async throws {
        let url = try Self.comfyPNG(in: try Fixtures.folder())
        let workflowBefore = PNGText.read(try Data(contentsOf: url)).first { $0.keyword == "workflow" }?.text
        // An XMP edit goes through ImageIO, which on its own drops unknown text chunks.
        try await MetadataEngine.save([.set("img.description", "dc:title", "Lighthouse")], for: url)
        let chunks = PNGText.read(try Data(contentsOf: url))
        #expect(chunks.first { $0.keyword == "workflow" }?.text == workflowBefore)
        #expect(chunks.first { $0.keyword == "prompt" } != nil)
        // The PNG's own Title chunk follows the edit; the XMP copy is hidden as a duplicate of it.
        let report = await MetadataEngine.inspect(url)
        #expect(report.value("png:Title") == "Lighthouse")
        #expect(report.entry("dc:title") == nil)
        let tree = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        #expect(tree.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "dc:title" as CFString) as String? } == "Lighthouse")
        #expect(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.width == 64)
    }

    @Test func textChunksCanBeEditedRemovedAndAdded() async throws {
        let url = try Self.comfyPNG(in: try Fixtures.folder())
        try await MetadataEngine.save([.remove("img.generation", "png:prompt"), .set("img.pngtext", "png:Comment", "changed"),
                                       .set("img.pngtext", "png:Source", "Studio ✦"), .set("img.camera", "tiff:Make", "OtherCam")], for: url)
        let report = await MetadataEngine.inspect(url)
        #expect(report.entry("png:prompt") == nil)
        #expect(report.entry("png:workflow") != nil)
        #expect(report.value("png:Comment") == "changed")
        #expect(report.value("png:Source") == "Studio ✦")
        #expect(report.value("png:Title") == "Phare ☀︎ au crépuscule")
        #expect(report.value("tiff:Make") == "OtherCam")
        // With the node graph gone, the summary comes from what's left (the workflow's node count).
        #expect(report.section("img.generation.summary")?.entries.contains { $0.label == "Seed" } != true)
    }

    @Test func cleanRemovesGeneratorData() async throws {
        let url = try Self.comfyPNG(in: try Fixtures.folder())
        let result = try await MetadataEngine.clean(url, options: CleanOptions(keepOrientation: false), destination: .overwrite)
        #expect(result.remaining.isEmpty)
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("class_type".utf8)) == nil && data.range(of: Data("workflow".utf8)) == nil)
        #expect(await MetadataEngine.inspect(url).section("img.generation.summary") == nil)
    }

    @Test func automatic1111ParametersInJPEG() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appendingPathComponent("00012-42.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let parameters = "a cat on a sofa, soft light\nNegative prompt: lowres, watermark\nSteps: 20, Sampler: Euler a, Schedule type: Karras, CFG scale: 7, Seed: 42, Size: 512x768, Model hash: abc123, Model: dreamshaper_8, Lora hashes: \"detail: 1a2b\", Version: v1.10.1"
        CGImageDestinationAddImage(destination, Fixtures.picture(),
                                   [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: parameters]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let report = await MetadataEngine.inspect(url)
        #expect(report.entry("exif:UserComment")?.label == "Generation parameters")
        #expect(report.entry("exif:UserComment")?.isEditable == true)  // plain text stays editable
        #expect(report.section("img.generation")?.entries.count == 1)
        let fields = Dictionary((report.section("img.generation.summary")?.entries ?? []).map { ($0.label, $0.value) },
                                uniquingKeysWith: { first, _ in first })
        #expect(fields["Positive prompt"] == "a cat on a sofa, soft light")
        #expect(fields["Negative prompt"] == "lowres, watermark")
        #expect(fields["Seed"] == "42")
        #expect(fields["Steps"] == "20")
        #expect(fields["Sampler"] == "Euler a")
        #expect(fields["Scheduler"] == "Karras")
        #expect(fields["CFG"] == "7")
        #expect(fields["Model"] == "dreamshaper_8")
        #expect(fields["Size"] == "512x768")
        #expect(fields["Generator"] == "v1.10.1")

        let result = try await MetadataEngine.clean(url, options: CleanOptions(), destination: .overwrite)
        #expect(result.remaining.isEmpty)
    }

    @Test func flatJSONGenerators() {
        let swarm = Self.json(["sui_image_params": ["prompt": "a fox", "negativeprompt": "blur", "model": "flux-dev", "seed": 7, "steps": 30,
                                                    "cfgscale": 3.5, "width": 1024, "height": 1024] as [String: Any]])
        let fields = Dictionary(GenerationInfo.summary([swarm]).map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        #expect(fields["Positive prompt"] == "a fox")
        #expect(fields["Negative prompt"] == "blur")
        #expect(fields["Model"] == "flux-dev")
        #expect(fields["CFG"] == "3.5")
        #expect(fields["Size"] == "1024 × 1024")
    }
}
