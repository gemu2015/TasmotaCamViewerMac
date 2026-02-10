import Foundation
import AppKit

/// Parses an MJPEG multipart HTTP stream into individual JPEG frames.
/// Thread safety is provided by the URLSession serial delegate queue.
///
/// The Tasmota ESP32-CAM wire format:
/// ```
/// --<boundary>\r\n
/// Content-Type: image/jpeg\r\n
/// Content-Length: <length>\r\n
/// \r\n
/// <JPEG binary data>
/// \r\n
/// ```
final class MJPEGStreamParser {

    // MARK: - Types

    private enum ParserState {
        case seekingBoundary
        case readingHeaders
        case readingBody(expectedLength: Int?)
    }

    // MARK: - Properties

    private let boundaryMarker: Data  // "--<boundary>" as Data
    private let headerEnd: Data       // "\r\n\r\n" as Data
    private let lineEnd: Data         // "\r\n" as Data

    private var buffer: Data
    private var state: ParserState = .seekingBoundary

    // Statistics
    private(set) var totalFrames: Int = 0
    private(set) var droppedFrames: Int = 0

    // MARK: - Init

    /// Initialize with a boundary string.
    /// - Parameter boundary: The multipart boundary (without the leading "--").
    ///   Defaults to the known Tasmota boundary.
    init(boundary: String = Constants.defaultTasmotaBoundary) {
        self.boundaryMarker = Data("--\(boundary)".utf8)
        self.headerEnd = Data("\r\n\r\n".utf8)
        self.lineEnd = Data("\r\n".utf8)
        self.buffer = Data(capacity: Constants.parserBufferInitialCapacity)
        print("[Parser] Init with boundary: '--\(boundary)' (\(self.boundaryMarker.count) bytes)")
    }

    // MARK: - Public

    /// Feed raw bytes received from the network into the parser.
    /// Returns an array of decoded NSImage frames (typically 0 or 1 per call).
    func feed(_ data: Data) -> [NSImage] {
        buffer.append(data)
        var frames: [NSImage] = []

        // Process buffer in a loop — one feed() call may contain multiple frames
        while true {
            switch state {
            case .seekingBoundary:
                guard let boundaryRange = buffer.range(of: boundaryMarker) else {
                    let keep = max(0, buffer.count - boundaryMarker.count)
                    if keep > 0 {
                        buffer.removeFirst(keep)
                    }
                    return frames
                }
                let afterBoundary = boundaryRange.upperBound
                guard let lineEndRange = buffer.range(of: lineEnd, in: afterBoundary..<buffer.endIndex) else {
                    return frames
                }
                buffer.removeSubrange(buffer.startIndex..<lineEndRange.upperBound)
                state = .readingHeaders

            case .readingHeaders:
                guard let headerEndRange = buffer.range(of: headerEnd) else {
                    return frames
                }
                let headersData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
                let contentLength = parseContentLength(from: headersData)
                buffer.removeSubrange(buffer.startIndex..<headerEndRange.upperBound)
                state = .readingBody(expectedLength: contentLength)

            case .readingBody(let expectedLength):
                if let length = expectedLength {
                    guard buffer.count >= length else {
                        return frames
                    }
                    let jpegData = buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: length)]
                    buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: length))

                    if buffer.starts(with: lineEnd) {
                        buffer.removeFirst(lineEnd.count)
                    }

                    if let image = decodeFrame(Data(jpegData)) {
                        frames.append(image)
                        totalFrames += 1
                    } else {
                        droppedFrames += 1
                    }
                    state = .seekingBoundary

                } else {
                    guard let nextBoundaryRange = buffer.range(of: boundaryMarker) else {
                        if buffer.count > 2_000_000 {
                            buffer.removeAll()
                            state = .seekingBoundary
                            droppedFrames += 1
                        }
                        return frames
                    }

                    var frameEnd = nextBoundaryRange.lowerBound
                    if frameEnd >= buffer.index(buffer.startIndex, offsetBy: lineEnd.count) {
                        let possibleLineEnd = buffer.index(frameEnd, offsetBy: -lineEnd.count)
                        if buffer[possibleLineEnd..<frameEnd] == lineEnd {
                            frameEnd = possibleLineEnd
                        }
                    }

                    let jpegData = buffer[buffer.startIndex..<frameEnd]
                    buffer.removeSubrange(buffer.startIndex..<nextBoundaryRange.lowerBound)

                    if let image = decodeFrame(Data(jpegData)) {
                        frames.append(image)
                        totalFrames += 1
                    } else {
                        droppedFrames += 1
                    }
                    state = .seekingBoundary
                }
            }
        }
    }

    /// Reset the parser state. Call when reconnecting.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        state = .seekingBoundary
    }

    // MARK: - Private

    /// Parse "Content-Length: <value>" from raw header bytes.
    private func parseContentLength(from headersData: Data) -> Int? {
        guard let headersString = String(data: headersData, encoding: .ascii) else {
            return nil
        }
        let lines = headersString.components(separatedBy: "\r\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("content-length:") {
                let valueString = trimmed.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(valueString)
            }
        }
        return nil
    }

    /// Validate JPEG SOI marker and decode to NSImage.
    private func decodeFrame(_ data: Data) -> NSImage? {
        guard data.count >= 2 else { return nil }

        let firstTwo = [data[data.startIndex], data[data.index(after: data.startIndex)]]
        guard firstTwo[0] == 0xFF, firstTwo[1] == 0xD8 else {
            return nil
        }

        return NSImage(data: data)
    }
}
