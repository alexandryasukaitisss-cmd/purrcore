import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imports one horizontal PNG strip. All frames are committed as one atomic file.
public struct PetAnimationStore: Sendable {
    public static let frameCount = 8
    private let directory: URL
    private var animationURL: URL { directory.appendingPathComponent("animation.png") }

    public init(applicationSupportDirectory: URL) {
        directory = applicationSupportDirectory.appendingPathComponent("Pet", isDirectory: true)
    }

    public func load() throws -> [CGImage]? {
        guard FileManager.default.fileExists(atPath: animationURL.path) else { return nil }
        return try frames(in: readStrip(from: animationURL))
    }

    public func importAnimation(from url: URL) throws -> [CGImage] {
        let strip = try readStrip(from: url)
        let result = try frames(in: strip)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PetAnimationError.invalidStrip
        }
        CGImageDestinationAddImage(destination, strip, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetAnimationError.invalidStrip }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try (data as Data).write(to: animationURL, options: .atomic)
        return result
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: animationURL.path) {
            try FileManager.default.removeItem(at: animationURL)
        }
    }

    private func readStrip(from url: URL) throws -> CGImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= PetPhotoStore.maximumInputBytes else {
            throw PetAnimationError.invalidStrip
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= PetPhotoStore.maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width >= 128, height >= 16, width > height, width <= 16_384, height <= 4_096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 3_072,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PetAnimationError.invalidStrip }
        return image
    }

    private func frames(in strip: CGImage) throws -> [CGImage] {
        let frames = try (0..<Self.frameCount).map { index in
            let start = index * strip.width / Self.frameCount
            let end = (index + 1) * strip.width / Self.frameCount
            guard let frame = strip.cropping(to: CGRect(x: start, y: 0, width: end - start, height: strip.height)) else {
                throw PetAnimationError.invalidStrip
            }
            return frame
        }
        return try trimSharedTransparentMargins(frames)
    }

    // One crop for the whole cycle preserves the pet's scale and baseline.
    // Cropping each frame independently would make its size jump while running.
    private func trimSharedTransparentMargins(_ frames: [CGImage]) throws -> [CGImage] {
        var bounds = CGRect.null
        for frame in frames {
            guard let context = CGContext(
                data: nil, width: frame.width, height: frame.height,
                bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ), let data = context.data else { throw PetAnimationError.invalidStrip }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var left = frame.width, top = frame.height, right = -1, bottom = -1
            for y in 0..<frame.height {
                for x in 0..<frame.width where pixels[y * context.bytesPerRow + x * 4 + 3] > 0 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= left, bottom >= top else { throw PetAnimationError.invalidStrip }
            bounds = bounds.union(CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
        }
        return try frames.map { frame in
            guard let cropped = frame.cropping(to: bounds) else { throw PetAnimationError.invalidStrip }
            return cropped
        }
    }
}

public enum PetAnimationError: LocalizedError, Equatable {
    case invalidStrip
    public var errorDescription: String? {
        "Выбери PNG до 20 МБ: восемь кадров в одном горизонтальном ряду, на прозрачном фоне."
    }
}
