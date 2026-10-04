import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps only a small PNG thumbnail, without the source photo's metadata or path.
public struct PetPhotoStore: Sendable {
    public static let maximumInputBytes = 20 * 1_024 * 1_024
    public static let maximumPixelSize = 1_024
    private let directory: URL

    public init(applicationSupportDirectory: URL) {
        directory = applicationSupportDirectory.appendingPathComponent("Pet", isDirectory: true)
    }

    public var referencePhotoURL: URL { directory.appendingPathComponent("photo.png") }

    public func load() throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: referencePhotoURL.path) else { return nil }
        return try thumbnail(from: referencePhotoURL)
    }

    public func importPhoto(from sourceURL: URL) throws -> CGImage {
        let image = try thumbnail(from: sourceURL)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PetPhotoError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetPhotoError.unreadableImage }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try (output as Data).write(to: referencePhotoURL, options: .atomic)
        return image
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: referencePhotoURL.path) {
            try FileManager.default.removeItem(at: referencePhotoURL)
        }
    }

    private func thumbnail(from url: URL) throws -> CGImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PetPhotoError.unreadableImage }
        guard let size = values.fileSize, size <= Self.maximumInputBytes else { throw PetPhotoError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumInputBytes else { throw PetPhotoError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PetPhotoError.unreadableImage }
        return image
    }
}

public enum PetPhotoError: LocalizedError, Equatable {
    case tooLarge
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Выбери фото размером не более 20 МБ."
        case .unreadableImage: return "Не удалось открыть изображение. Попробуй JPEG, PNG, HEIC или TIFF."
        }
    }
}
