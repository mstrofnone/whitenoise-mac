import Foundation

/// Admission before ImageIO/AppKit see the animation. Encoded size and view scaling alone do
/// not bound a GIF's logical canvas or the work required to composite all its frames.
///
/// The area cap matches iOS and bounds the one raster the loader decodes to prove ImageIO can
/// play the file at all: ImageIO has its own undocumented limits (it refuses large canvases and
/// tiny frames on a canvas that is large for the file size) that no header check reproduces.
nonisolated enum GIFPlaybackAdmission {
    static let maximumEdge = 4_096
    static let maximumCanvasPixels = 4 * 1_024 * 1_024
    static let maximumFrames = 1_000
    static let maximumCanvasPixelsAcrossFrames = 32 * 1_024 * 1_024

    struct Metadata: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameCount: Int
    }

    /// Why a container was refused. Logged publicly so field refusals can be told apart.
    enum Rejection: String, Error, Equatable, Sendable {
        case size, signature, canvas, area, frames, aggregate, rect, reservedBits, codeSize
        case `extension`, block, truncated, trailingData
    }

    /// Walks bounded headers/sub-blocks only; never decompresses pixels or allocates a raster.
    static func inspect(_ data: Data) -> Metadata? {
        try? evaluate(data).get()
    }

    /// `inspect`, with the reason for a refusal.
    static func evaluate(_ data: Data) -> Result<Metadata, Rejection> {
        guard data.count >= 14, data.count <= GiphySearchClient.maximumMediaBytes else { return .failure(.size) }
        var reader = Reader(bytes: Array(data))
        guard let signature = reader.take(6), let width = reader.word(), let height = reader.word() else {
            return .failure(.truncated)
        }
        guard signature == Array("GIF87a".utf8) || signature == Array("GIF89a".utf8) else {
            return .failure(.signature)
        }
        guard (1...maximumEdge).contains(width), (1...maximumEdge).contains(height) else {
            return .failure(.canvas)
        }
        guard width * height <= maximumCanvasPixels else { return .failure(.area) }
        guard let flags = reader.byte(), reader.skip(2), reader.skipColorTable(flags) else {
            return .failure(.truncated)
        }

        // The edge cap makes this product safe; division keeps the aggregate check independent
        // of the frame count and prevents multiplication overflow if limits change later.
        let canvasPixels = width * height
        var frames = 0
        while let marker = reader.byte() {
            switch marker {
            case 0x3B:  // Trailer: require the entire container, not a valid prefix.
                guard reader.isAtEnd else { return .failure(.trailingData) }
                guard frames > 1 else { return .failure(.frames) }
                return .success(Metadata(width: width, height: height, frameCount: frames))
            case 0x21:  // Extension. Every recognized extension uses bounded sub-blocks.
                guard let label = reader.byte() else { return .failure(.truncated) }
                switch label {
                case 0xF9:
                    guard let size = reader.byte(), reader.skip(4), let terminator = reader.byte() else {
                        return .failure(.truncated)
                    }
                    guard size == 4, terminator == 0 else { return .failure(.extension) }
                case 0xFF:
                    guard let size = reader.byte() else { return .failure(.truncated) }
                    guard size == 11 else { return .failure(.extension) }
                    guard reader.skip(11), reader.skipSubBlocks() else { return .failure(.truncated) }
                case 0xFE:
                    guard reader.skipSubBlocks() else { return .failure(.truncated) }
                default:
                    // Do not admit plaintext rendering or unknown rendering extensions without
                    // an explicit resource policy for those additional drawing operations.
                    return .failure(.extension)
                }
            case 0x2C:  // Image descriptor; partial frames must stay inside the logical canvas.
                guard let left = reader.word(), let top = reader.word(),
                    let frameWidth = reader.word(), let frameHeight = reader.word()
                else { return .failure(.truncated) }
                guard frameWidth > 0, frameHeight > 0,
                    left <= width, frameWidth <= width - left,
                    top <= height, frameHeight <= height - top
                else { return .failure(.rect) }
                guard let frameFlags = reader.byte() else { return .failure(.truncated) }
                guard frameFlags & 0x18 == 0 else { return .failure(.reservedBits) }
                guard reader.skipColorTable(frameFlags), let codeSize = reader.byte() else {
                    return .failure(.truncated)
                }
                guard (2...8).contains(codeSize) else { return .failure(.codeSize) }
                frames += 1
                guard frames <= maximumFrames else { return .failure(.frames) }
                guard canvasPixels <= maximumCanvasPixelsAcrossFrames / frames else { return .failure(.aggregate) }
                guard reader.skipSubBlocks() else { return .failure(.truncated) }
            default:
                return .failure(.block)
            }
        }
        return .failure(.truncated)
    }

    private struct Reader {
        let bytes: [UInt8]
        private var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func word() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return Int(low) | (Int(high) << 8)
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - offset else { return nil }
            let result = Array(bytes[offset..<(offset + count)])
            offset += count
            return result
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= bytes.count - offset else { return false }
            offset += count
            return true
        }

        mutating func skipColorTable(_ flags: UInt8) -> Bool {
            flags & 0x80 == 0 || skip(3 * (1 << (Int(flags & 0x07) + 1)))
        }

        mutating func skipSubBlocks() -> Bool {
            while let count = byte() {
                if count == 0 { return true }
                guard skip(Int(count)) else { return false }
            }
            return false
        }
    }
}
