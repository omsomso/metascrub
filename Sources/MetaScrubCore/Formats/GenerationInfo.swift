import Foundation

/// Recognises what AI image generators store in their images (ComfyUI node graphs, Automatic1111/Forge
/// parameter text, InvokeAI, SwarmUI, NovelAI and Fooocus JSON) and pulls out a readable summary.
enum GenerationInfo {
    /// PNG text keywords used by generators, with readable names.
    static let keywordLabels: [String: String] = [
        "prompt": "ComfyUI prompt (node graph)", "workflow": "ComfyUI workflow", "parameters": "Generation parameters",
        "invokeai_metadata": "InvokeAI metadata", "invokeai_graph": "InvokeAI graph", "invokeai_workflow": "InvokeAI workflow",
        "sd-metadata": "InvokeAI metadata (legacy)", "dream": "InvokeAI prompt (legacy)", "sui_image_params": "SwarmUI parameters",
        "fooocus_scheme": "Fooocus scheme", "generation_data": "Generation data",
    ]

    static func label(forKeyword keyword: String) -> String? {
        keywordLabels[keyword.lowercased()]
    }

    /// For text found in EXIF/XMP fields (JPEG and WebP generators write there): a label when it is generation data.
    static func label(forFieldText text: String) -> String? {
        if text.hasPrefix("workflow:") { return "ComfyUI workflow" }
        if text.hasPrefix("prompt:") { return "ComfyUI prompt (node graph)" }
        if text.hasPrefix("{"), text.contains("\"class_type\"") { return "ComfyUI prompt (node graph)" }
        if text.contains("Steps: "), text.contains("Sampler: ") || text.contains("Seed: ") { return "Generation parameters" }
        return nil
    }

    /// Readable fields from every source, the first value for each label winning.
    static func summary(_ sources: [String]) -> [(String, String)] {
        var result: [(String, String)] = []
        for source in sources {
            for (label, value) in fields(source) where !value.isEmpty && !result.contains(where: { $0.0 == label }) {
                result.append((label, value))
            }
        }
        let order = ["Generator", "Model", "LoRA", "Positive prompt", "Negative prompt", "Prompt text", "Seed", "Steps", "CFG",
                     "Sampler", "Scheduler", "Denoise", "Size", "Nodes"]
        return result.sorted { (order.firstIndex(of: $0.0) ?? order.count) < (order.firstIndex(of: $1.0) ?? order.count) }
    }

    static func fields(_ source: String) -> [(String, String)] {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["workflow:", "prompt:"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            if let graph = comfyGraph(object) { return comfy(graph) }
            if let nodes = object["nodes"] as? [Any] { return [("Nodes", "\(nodes.count)"), ("Generator", "ComfyUI")] }
            return flat(object)
        }
        if text.contains("Steps: ") { return automatic1111(text) }
        return []
    }

    // MARK: ComfyUI

    private static func comfyGraph(_ object: [String: Any]) -> [String: [String: Any]]? {
        let nodes = object.compactMapValues { $0 as? [String: Any] }.filter { $0.value["class_type"] is String }
        return nodes.isEmpty ? nil : nodes
    }

    private static func comfy(_ graph: [String: [String: Any]]) -> [(String, String)] {
        func inputs(_ id: String) -> [String: Any] { graph[id]?["inputs"] as? [String: Any] ?? [:] }
        func linked(_ value: Any?) -> String? {
            guard let pair = value as? [Any], let first = pair.first else { return nil }
            return "\(first)"
        }
        /// Follows links back to the text that feeds a conditioning or string input.
        func text(_ value: Any?, depth: Int = 0) -> String? {
            if let string = value as? String { return string }
            guard depth < 6, let id = linked(value) else { return nil }
            let node = inputs(id)
            for key in ["text", "text_g", "prompt", "string", "value", "text_l", "conditioning", "conditioning_1", "conditioning_to"] {
                if node[key] != nil, let found = text(node[key], depth: depth + 1) { return found }
            }
            return nil
        }
        func number(_ value: Any?, depth: Int = 0) -> String? {
            if let number = value as? NSNumber { return format(number) }
            guard depth < 4, let id = linked(value) else { return nil }
            let node = inputs(id)
            for key in ["seed", "noise_seed", "value", "int", "float"] where node[key] != nil {
                if let found = number(node[key], depth: depth + 1) { return found }
            }
            return nil
        }

        var fields: [(String, String)] = [("Generator", "ComfyUI")]
        let ids = graph.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
        var models: [String] = [], loras: [String] = []
        for id in ids {
            let node = inputs(id)
            for key in ["ckpt_name", "unet_name", "model_name"] {
                if let name = node[key] as? String, !models.contains(name) { models.append(name) }
            }
            if let name = node["lora_name"] as? String, !loras.contains(name) { loras.append(name) }
        }
        if !models.isEmpty { fields.append(("Model", models.joined(separator: ", "))) }
        if !loras.isEmpty { fields.append(("LoRA", loras.joined(separator: ", "))) }

        let samplerID = ids.first { id in
            let type = graph[id]?["class_type"] as? String ?? ""
            let node = inputs(id)
            return type.contains("Sampler") && (node["steps"] != nil || node["seed"] != nil || node["noise_seed"] != nil || node["noise"] != nil)
        }
        if let samplerID {
            var sampler = inputs(samplerID)
            // Custom sampler graphs keep prompts and CFG in a guider node, and the seed in a noise node.
            if let guider = linked(sampler["guider"]) { sampler.merge(inputs(guider)) { current, _ in current } }
            if let noise = linked(sampler["noise"]) { sampler.merge(inputs(noise)) { current, _ in current } }
            if let positive = text(sampler["positive"]) { fields.append(("Positive prompt", positive)) }
            if let negative = text(sampler["negative"]), !negative.isEmpty { fields.append(("Negative prompt", negative)) }
            if let seed = number(sampler["seed"]) ?? number(sampler["noise_seed"]) { fields.append(("Seed", seed)) }
            if let steps = number(sampler["steps"]) { fields.append(("Steps", steps)) }
            if let cfg = number(sampler["cfg"]) { fields.append(("CFG", cfg)) }
            if let name = sampler["sampler_name"] as? String { fields.append(("Sampler", name)) }
            if let scheduler = sampler["scheduler"] as? String { fields.append(("Scheduler", scheduler)) }
            if let denoise = number(sampler["denoise"]), denoise != "1" { fields.append(("Denoise", denoise)) }
        }
        if !fields.contains(where: { $0.0 == "Positive prompt" }) {
            let texts = ids.filter { (graph[$0]?["class_type"] as? String)?.hasPrefix("CLIPTextEncode") == true }
                .compactMap { inputs($0)["text"] as? String }.filter { !$0.isEmpty }
            if !texts.isEmpty { fields.append(("Prompt text", texts.joined(separator: "\n\n"))) }
        }
        if let latent = ids.first(where: { (graph[$0]?["class_type"] as? String)?.contains("LatentImage") == true }),
           let width = number(inputs(latent)["width"]), let height = number(inputs(latent)["height"]) {
            fields.append(("Size", "\(width) × \(height)"))
        }
        fields.append(("Nodes", "\(graph.count)"))
        return fields
    }

    // MARK: Automatic1111 / Forge

    /// "prompt\nNegative prompt: …\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Size: 512x512, Model: x"
    private static func automatic1111(_ text: String) -> [(String, String)] {
        let lines = text.components(separatedBy: "\n")
        guard let settingsIndex = lines.lastIndex(where: { $0.contains("Steps: ") }) else { return [] }
        var positive: [String] = [], negative: [String] = []
        var inNegative = false
        for line in lines[..<settingsIndex] {
            if line.hasPrefix("Negative prompt:") {
                inNegative = true
                negative.append(String(line.dropFirst("Negative prompt:".count)).trimmingCharacters(in: .whitespaces))
            } else if inNegative {
                negative.append(line)
            } else {
                positive.append(line)
            }
        }
        var fields: [(String, String)] = [("Generator", "Automatic1111-style")]
        fields.append(("Positive prompt", positive.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        fields.append(("Negative prompt", negative.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        let names = ["Model": "Model", "Steps": "Steps", "Sampler": "Sampler", "Schedule type": "Scheduler", "CFG scale": "CFG",
                     "Seed": "Seed", "Size": "Size", "Denoising strength": "Denoise", "Version": "Generator", "Lora hashes": "LoRA"]
        for part in splitSettings(lines[settingsIndex]) {
            let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { continue }
            let value = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let label = names[pieces[0]] {
                if label == "Generator" { fields[0] = ("Generator", value) } else { fields.append((label, value)) }
            }
        }
        return fields
    }

    /// Splits on ", " outside double quotes.
    private static func splitSettings(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var previous: Character = " "
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == " " && previous == "," && !quoted {
                parts.append(String(current.dropLast()))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: Flat JSON (InvokeAI, SwarmUI, NovelAI, Fooocus)

    private static func flat(_ json: [String: Any]) -> [(String, String)] {
        var object = json
        if object.count == 1, let inner = object.values.first as? [String: Any] { object = inner }
        let lowered = Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func pick(_ keys: [String]) -> String? {
            for key in keys {
                guard let value = lowered[key] else { continue }
                if let string = value as? String, !string.isEmpty { return string }
                if let number = value as? NSNumber { return format(number) }
                if let nested = value as? [String: Any], let name = (nested["name"] ?? nested["model_name"] ?? nested["key"]) as? String {
                    return name
                }
            }
            return nil
        }
        var fields: [(String, String)] = []
        if let model = pick(["model", "model_name", "checkpoint", "ckpt_name", "base_model"]) { fields.append(("Model", model)) }
        if let positive = pick(["positive_prompt", "prompt", "positive"]) { fields.append(("Positive prompt", positive)) }
        if let negative = pick(["negative_prompt", "negativeprompt", "uc", "negative"]) { fields.append(("Negative prompt", negative)) }
        if let seed = pick(["seed", "noise_seed"]) { fields.append(("Seed", seed)) }
        if let steps = pick(["steps"]) { fields.append(("Steps", steps)) }
        if let cfg = pick(["cfg_scale", "cfgscale", "cfg", "scale", "guidance_scale"]) { fields.append(("CFG", cfg)) }
        if let sampler = pick(["sampler", "sampler_name"]) { fields.append(("Sampler", sampler)) }
        if let scheduler = pick(["scheduler"]) { fields.append(("Scheduler", scheduler)) }
        if let width = pick(["width"]), let height = pick(["height"]) { fields.append(("Size", "\(width) × \(height)")) }
        return fields
    }

    private static func format(_ number: NSNumber) -> String {
        let value = number.doubleValue
        return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%g", value)
    }
}
