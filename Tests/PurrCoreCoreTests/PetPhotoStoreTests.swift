import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PurrCoreCore

final class PetPhotoStoreTests: XCTestCase {
    private var root: URL!
    private var store: PetPhotoStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PetPhotoStore(applicationSupportDirectory: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testImportDownsamplesAndRemovesSourceMetadata() throws {
        let source = try fixture(width: 1_200, height: 600, metadata: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private fixture author"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0]
        ])
        let image = try store.importPhoto(from: source)
        XCTAssertEqual(image.width, 1_024)
        XCTAssertEqual(image.height, 512)
        let saved = root.appendingPathComponent("Pet/photo.png")
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(saved as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(try XCTUnwrap(store.load()).width, 1_024)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.deletingLastPathComponent().path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testImportAppliesPhotoOrientation() throws {
        let source = try fixture(width: 1_200, height: 600, metadata: [kCGImagePropertyOrientation: 6])
        let image = try store.importPhoto(from: source)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 1_024)
    }

    func testFailedReplacementKeepsPreviousPhoto() throws {
        _ = try store.importPhoto(from: fixture(width: 80, height: 40))
        let invalid = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try store.importPhoto(from: invalid))
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.width, 80)
        XCTAssertEqual(restored.height, 40)
    }

    func testReplacementUpdatesPersistedPhoto() throws {
        _ = try store.importPhoto(from: fixture(width: 80, height: 40))
        _ = try store.importPhoto(from: fixture(width: 40, height: 80))
        let reopened = PetPhotoStore(applicationSupportDirectory: root)
        XCTAssertEqual(try XCTUnwrap(reopened.load()).height, 80)
    }

    func testRejectsOversizedFileBeforeDecoding() throws {
        let source = root.appendingPathComponent("large.png")
        try Data(repeating: 0, count: PetPhotoStore.maximumInputBytes + 1).write(to: source)
        XCTAssertThrowsError(try store.importPhoto(from: source)) { error in
            XCTAssertEqual(error as? PetPhotoError, .tooLarge)
        }
        XCTAssertNil(try store.load())
    }

    func testResetPreservesHistoryAndSourcePhoto() throws {
        let source = try fixture(width: 80, height: 40)
        let history = root.appendingPathComponent("history.sqlite3")
        try Data("history fixture".utf8).write(to: history)
        _ = try store.importPhoto(from: source)
        try store.reset()
        try store.reset()
        XCTAssertNil(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: history), Data("history fixture".utf8))
    }

    private func fixture(width: Int, height: Int, metadata: [CFString: Any] = [:]) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
