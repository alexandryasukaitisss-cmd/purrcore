import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PurrCoreCore

final class PetAnimationStoreTests: XCTestCase {
    private var root: URL!
    private var store: PetAnimationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PetAnimationStore(applicationSupportDirectory: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testImportsAllEightFramesInOrderAndPreservesAlpha() throws {
        let frames = try store.importAnimation(from: fixture(width: 1_024, height: 128))
        XCTAssertEqual(frames.count, 8)
        var previousRed = -1
        for frame in frames {
            XCTAssertEqual(frame.width, 128)
            XCTAssertEqual(frame.height, 128)
            let pixel = try centerPixel(frame)
            XCTAssertGreaterThan(Int(pixel[0]), previousRed)
            previousRed = Int(pixel[0])
            XCTAssertEqual(Double(pixel[3]), 127.5, accuracy: 1)
        }
        XCTAssertEqual(try centerPixel(frames[0])[0], 0)
        XCTAssertEqual(Double(try centerPixel(frames[7])[0]), 127.5, accuracy: 1)
    }

    func testOddWidthIncludesEveryColumn() throws {
        let frames = try store.importAnimation(from: fixture(width: 513, height: 64))
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width }, 513)
        XCTAssertEqual(frames.map(\.width), [64, 64, 64, 64, 64, 64, 64, 65])
    }

    func testLargeStripIsBoundedAndPersistsWithoutMetadata() throws {
        let frames = try store.importAnimation(from: fixture(width: 6_144, height: 384))
        XCTAssertEqual(frames.map(\.width), Array(repeating: 384, count: 8))
        let reopened = PetAnimationStore(applicationSupportDirectory: root)
        XCTAssertEqual(try XCTUnwrap(reopened.load()).count, 8)
        let url = root.appendingPathComponent("Pet/animation.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary as String])
    }

    func testInvalidReplacementKeepsPreviousAnimation() throws {
        _ = try store.importAnimation(from: fixture(width: 1_024, height: 128))
        XCTAssertThrowsError(try store.importAnimation(from: fixture(width: 64, height: 128)))
        let corrupt = root.appendingPathComponent("broken.png")
        try Data("broken".utf8).write(to: corrupt)
        XCTAssertThrowsError(try store.importAnimation(from: corrupt))
        XCTAssertEqual(try XCTUnwrap(store.load()).count, 8)
    }

    func testResetOnlyRemovesAnimation() throws {
        let photo = root.appendingPathComponent("Pet/photo.png")
        _ = try store.importAnimation(from: fixture(width: 1_024, height: 128))
        try Data("reference fixture".utf8).write(to: photo)
        try store.reset()
        try store.reset()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try Data(contentsOf: photo), Data("reference fixture".utf8))
    }

    func testSharedTransparentMarginsAreRemovedWithoutRescalingIndividualFrames() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1_024, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for index in 0..<8 {
            // Different poses share a baseline and must keep one common crop.
            let width = index == 0 ? 64 : 32
            context.fill(CGRect(x: index * 128 + 24, y: 20, width: width, height: 32))
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent("padded-strip.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let frames = try store.importAnimation(from: url)
        XCTAssertEqual(frames.map(\.width), Array(repeating: 64, count: 8))
        XCTAssertEqual(frames.map(\.height), Array(repeating: 32, count: 8))
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.map(\.width), frames.map(\.width))
        XCTAssertEqual(reopened.map(\.height), frames.map(\.height))
        // The smaller pose still occupies half the shared canvas, not the full width.
        XCTAssertEqual(Double(try centerPixel(frames[0])[3]), 255, accuracy: 1)
        XCTAssertEqual(Double(try centerPixel(frames[1])[3]), 127.5, accuracy: 5)
    }

    private func fixture(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for index in 0..<8 {
            context.setFillColor(CGColor(red: Double(index) / 7, green: 0.4, blue: 0.2, alpha: 0.5))
            let start = index * width / 8
            let end = (index + 1) * width / 8
            context.fill(CGRect(x: start, y: 0, width: end - start, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private fixture"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: 4))
    }
}
