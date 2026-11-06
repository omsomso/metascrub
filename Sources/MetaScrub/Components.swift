import AppKit
import MetaScrubCore
import QuickLookThumbnailing
import SwiftUI

enum Thumbnails {
    /// A Quick Look preview, or the Finder icon when there is none.
    static func image(for url: URL, size: CGFloat) async -> NSImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Highlight {
    var color: Color {
        switch self {
        case .location: return .red
        case .device: return .orange
        case .people: return .purple
        case .history: return .blue
        }
    }
}

/// A small coloured capsule naming a kind of personal data.
struct HighlightChip: View {
    let highlight: Highlight
    var compact = false

    var body: some View {
        Label(highlight.title, systemImage: highlight.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(highlight.color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .background(highlight.color.opacity(0.13), in: Capsule())
            .help(help)
    }

    private var help: String {
        switch highlight {
        case .location: return "Contains where the file was made (GPS coordinates or place names)."
        case .device: return "Names the camera, phone or software that made the file."
        case .people: return "Contains names of authors, artists or owners."
        case .history: return "Records where the file came from or how it was edited."
        }
    }
}

struct FactChip: View {
    let fact: Fact

    var body: some View {
        Label(fact.value, systemImage: fact.symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(fact.label)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The big empty-state target for dropping files.
struct DropZone: View {
    let symbol: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let isTargeted: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: isTargeted)
                .frame(width: 116, height: 116)
                .glassEffect(.regular.tint(Color.accentColor.opacity(isTargeted ? 0.35 : 0.08)), in: .circle)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button(buttonTitle, action: action)
                .buttonStyle(.glass)
                .controlSize(.large)
            HStack(spacing: 14) {
                ForEach([("photo", "Photos"), ("music.note", "Audio"), ("film", "Video"), ("doc.richtext", "PDF"),
                         ("doc.text", "Office"), ("doc", "Any file")], id: \.1) { symbol, name in
                    Label(name, systemImage: symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .background(isTargeted ? Color.accentColor.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(24)
        }
        .animation(.easeOut(duration: 0.18), value: isTargeted)
    }
}

/// Card background used for content blocks in the viewer.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

extension URL {
    var fileSizeText: String {
        let size = (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
