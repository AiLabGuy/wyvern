// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

/// Upload policy: magic bytes and the declared extension (and UTType, when one is
/// passed) must name the same allowed kind. A valid PNG renamed to `.gif` or `.txt`
/// is rejected. A `.png` whose bytes are SVG, XML, PDF, or garbage is rejected.
final class IconUploadTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-icons-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testRejectsOversizeBeforeReadingAndOnTheBuffer() throws {
        let url = directory.appendingPathComponent("big.png")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let opened = url.path.withCString { path -> Int32 in
            #if canImport(Darwin)
            return Darwin.open(path, O_RDWR)
            #else
            return Glibc.open(path, O_RDWR)
            #endif
        }
        XCTAssertGreaterThanOrEqual(opened, 0)
        XCTAssertEqual(ftruncate(opened, off_t(IconUpload.maxBytes + 1)), 0)
        _ = close(opened)
        XCTAssertEqual(failure(IconUpload.readBounded(at: url)), .tooLarge)

        let declared = IconUpload.validate(
            data: Data([0x89, 0x50]),
            fileExtension: "png",
            declaredByteCount: Int64(IconUpload.maxBytes + 1)
        )
        XCTAssertEqual(failure(declared), .tooLarge)

        let buffer = Data(count: IconUpload.maxBytes + 1)
        XCTAssertEqual(failure(IconUpload.validate(data: buffer, fileExtension: "png")), .tooLarge)
    }

    func testRejectsSVGAndXMLEvenWhenNamedPNG() {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        XCTAssertEqual(failure(IconUpload.validate(data: svg, fileExtension: "png")), .unsupportedType)
        let xml = Data("<?xml version=\"1.0\"?><svg/>".utf8)
        XCTAssertEqual(failure(IconUpload.validate(data: xml, fileExtension: "png")), .unsupportedType)
        let padded = Data("\n\t<svg></svg>".utf8)
        XCTAssertEqual(failure(IconUpload.validate(data: padded, fileExtension: "png")), .unsupportedType)
        XCTAssertEqual(
            failure(IconUpload.validate(data: Data("%PDF-1.7".utf8), fileExtension: "png")),
            .unsupportedType
        )
    }

    func testRejectsGarbageAndEmpty() throws {
        XCTAssertEqual(failure(IconUpload.validate(data: Data([0, 1, 2, 3, 4]), fileExtension: "png")), .unsupportedType)
        XCTAssertEqual(failure(IconUpload.validate(data: Data(), fileExtension: "png")), .empty)
        let empty = directory.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertEqual(failure(IconUpload.readBounded(at: empty)), .empty)
    }

    /// A real PNG with a disallowed extension is rejected. The extension is part of the
    /// check, not a hint. See `IconUpload`.
    func testValidPNGWithWrongExtensionIsRejected() throws {
        let png = try tinyPNG()
        XCTAssertEqual(IconUpload.detectedKind(data: png), .png)
        XCTAssertEqual(failure(IconUpload.validate(data: png, fileExtension: "gif")), .extensionMismatch)
        XCTAssertEqual(failure(IconUpload.validate(data: png, fileExtension: "txt")), .extensionMismatch)
        XCTAssertEqual(failure(IconUpload.validate(data: png, fileExtension: "svg")), .extensionMismatch)
        XCTAssertEqual(failure(IconUpload.validate(data: png, fileExtension: "")), .extensionMismatch)
        XCTAssertEqual(
            failure(IconUpload.validate(data: png, fileExtension: "png", typeIdentifier: "public.jpeg")),
            .extensionMismatch
        )
        XCTAssertEqual(try successKind(IconUpload.validate(data: png, fileExtension: "png")), .png)
        XCTAssertEqual(
            try successKind(IconUpload.validate(data: png, fileExtension: "PNG", typeIdentifier: "public.png")),
            .png
        )
    }

    func testAcceptsJPEGAndHEICAndICNSHeadersOnlyWhenTheExtensionAgrees() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertEqual(try successKind(IconUpload.validate(data: jpeg, fileExtension: "jpg")), .jpeg)
        XCTAssertEqual(failure(IconUpload.validate(data: jpeg, fileExtension: "png")), .extensionMismatch)

        var icns = Data("icns".utf8)
        icns.append(Data(count: 8))
        XCTAssertEqual(try successKind(IconUpload.validate(data: icns, fileExtension: "icns")), .icns)

        var heic = Data(count: 12)
        heic[4] = 0x66
        heic[5] = 0x74
        heic[6] = 0x79
        heic[7] = 0x70
        heic.replaceSubrange(8..<12, with: Data("heic".utf8))
        XCTAssertEqual(try successKind(IconUpload.validate(data: heic, fileExtension: "heic")), .heic)
        XCTAssertEqual(failure(IconUpload.validate(data: heic, fileExtension: "png")), .extensionMismatch)
        XCTAssertNil(IconUpload.detectedKind(data: Data("avif-not-really".utf8)))
    }

    func testScaledSizeAndAbsurdDimensions() {
        XCTAssertEqual(IconUpload.maxDimension, 4_096)
        XCTAssertEqual(IconUpload.rejectedDimension(width: 0, height: 10), .decodeFailed)
        XCTAssertEqual(IconUpload.rejectedDimension(width: 4_097, height: 10), .absurdDimensions)
        XCTAssertNil(IconUpload.rejectedDimension(width: 4_096, height: 4_096))
        XCTAssertEqual(IconUpload.rejectedDimension(width: 16_384, height: 16_384), .absurdDimensions)
        XCTAssertEqual(IconUpload.scaledSize(width: 100, height: 80)?.width, 100)
        XCTAssertEqual(IconUpload.scaledSize(width: 100, height: 80)?.height, 80)
        let wide = IconUpload.scaledSize(width: 600, height: 200)
        XCTAssertEqual(wide?.width, 512)
        XCTAssertEqual(wide?.height, 170)
        let square = IconUpload.scaledSize(width: 800, height: 800)
        XCTAssertEqual(square?.width, 512)
        XCTAssertEqual(square?.height, 512)
        XCTAssertLessThanOrEqual(square?.width ?? 0, IconUpload.maxEdge)
        XCTAssertNil(IconUpload.scaledSize(width: 20_000, height: 10))
    }

    func testHostKeyMatchesOriginHostLowercasing() {
        XCTAssertEqual(IconHostKey.normalize("Example.COM"), "example.com")
        XCTAssertEqual(IconHostKey.normalize("https://Example.com/path"), "example.com")
        XCTAssertEqual(IconHostKey.normalize("https://example.com:443/a"), "example.com")
        XCTAssertEqual(IconHostKey.normalize("http://example.com:80"), "example.com")
        XCTAssertEqual(IconHostKey.normalize("https://example.com:8443/a"), "example.com:8443")
        XCTAssertEqual(IconHostKey.normalize("example.com:8443"), "example.com:8443")
        XCTAssertEqual(IconHostKey.normalize("www.example.com"), "www.example.com")
        XCTAssertEqual(
            IconHostKey.normalize(url: URL(string: "https://Example.com/path")!),
            "example.com"
        )
        XCTAssertEqual(SitePermissionPolicy.originKey(for: URL(string: "https://Example.com/path")!), "https://example.com")
        XCTAssertNil(IconHostKey.normalize("   "))
        XCTAssertNil(IconHostKey.normalize(url: URL(string: "about:blank")!))
    }

    func testStoredNamesAreUUIDFilesOnly() {
        let name = UUID().uuidString.lowercased() + ".png"
        XCTAssertTrue(IconUpload.isStoredFileName(name))
        XCTAssertFalse(IconUpload.isStoredFileName("../secrets.png"))
        XCTAssertFalse(IconUpload.isStoredFileName("wyvern.png"))
        XCTAssertFalse(IconUpload.isStoredFileName(name + ".txt"))
    }

    func testStoredPNGRequiresSmallIHDR() throws {
        let tiny = try tinyPNG()
        XCTAssertEqual(IconUpload.pngPixelSize(tiny)?.width, 1)
        XCTAssertEqual(IconUpload.pngPixelSize(tiny)?.height, 1)
        XCTAssertTrue(IconUpload.isAcceptableStoredPNG(tiny))

        let wide = pngHeader(width: 600, height: 200)
        XCTAssertEqual(IconUpload.detectedKind(data: wide), .png)
        XCTAssertEqual(IconUpload.pngPixelSize(wide)?.width, 600)
        XCTAssertEqual(IconUpload.pngPixelSize(wide)?.height, 200)
        XCTAssertFalse(IconUpload.isAcceptableStoredPNG(wide))

        let huge = pngHeader(width: 16_384, height: 16_384)
        XCTAssertFalse(IconUpload.isAcceptableStoredPNG(huge))
        XCTAssertFalse(IconUpload.isAcceptableStoredPNG(Data("<svg></svg>".utf8)))
        XCTAssertFalse(IconUpload.isAcceptableStoredPNG(Data()))
        XCTAssertNil(IconUpload.pngPixelSize(Data("icns".utf8)))
    }

    func testRefusesSymbolicLink() throws {
        let target = directory.appendingPathComponent("real.png")
        try tinyPNG().write(to: target)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(failure(IconUpload.readBounded(at: link)), .unreadable)
    }

    func testRefusesFIFOWithoutBlocking() {
        let fifo = directory.appendingPathComponent("pipe.png")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        // Without O_NONBLOCK, open() would wait here for a writer that never comes.
        XCTAssertEqual(failure(IconUpload.readBounded(at: fifo)), .unreadable)
    }

    func testIndexRoundTripPermissionsAndCorruptIndex() throws {
        let library = IconLibrary(directory: directory)
        try successVoid(library.setBuiltInAppIcon(.hermes))
        XCTAssertEqual(permission(library.directory), 0o700)
        XCTAssertEqual(permission(library.indexURL), 0o600)
        let reloaded = IconLibrary(directory: directory)
        XCTAssertEqual(reloaded.appIcon, .style(.hermes))

        let png = try tinyPNG()
        let bookmark = UUID()
        try successVoid(library.installPreparedPNG(png, forBookmark: bookmark))
        let stored = try XCTUnwrap(library.bookmarkIconURL(id: bookmark))
        XCTAssertEqual(permission(stored), 0o600)
        XCTAssertEqual(permission(library.directory), 0o700)
        XCTAssertTrue(IconUpload.isStoredFileName(stored.lastPathComponent))
        XCTAssertNotEqual(stored.lastPathComponent, "upload.png")
        let host = try successString(library.installPreparedPNG(png, forHost: "HTTPS://Example.com/a"))
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(library.hostKeys(), ["example.com"])
        let again = IconLibrary(directory: directory)
        XCTAssertNotNil(again.bookmarkIconURL(id: bookmark))
        XCTAssertNotNil(again.hostIconURL(key: "example.com"))
        XCTAssertEqual(again.appIcon, .style(.hermes))

        library.resetBookmarkIcon(id: bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertNil(library.bookmarkIconURL(id: bookmark))
        library.resetHostIcon("example.com")
        XCTAssertTrue(library.hostKeys().isEmpty)

        try successVoid(library.installPreparedPNGForAppIcon(png))
        let custom = try XCTUnwrap(library.customAppIconURL())
        XCTAssertEqual(permission(custom), 0o600)
        try successVoid(library.resetAppIcon())
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
        XCTAssertEqual(library.appIcon, .style(.default))
        XCTAssertEqual(IconLibrary(directory: directory).appIcon, .style(.default))

        try Data("{{".utf8).write(to: library.indexURL)
        let broken = IconLibrary(directory: directory)
        XCTAssertEqual(broken.appIcon, .style(.default))
        XCTAssertTrue(broken.hostKeys().isEmpty)
        XCTAssertNil(broken.bookmarkIconURL(id: bookmark))

        try Data("[]".utf8).write(to: library.indexURL)
        XCTAssertEqual(IconLibrary(directory: directory).appIcon, .style(.default))
    }

    func testPruneRemovesFilesForDeletedBookmarks() throws {
        let library = IconLibrary(directory: directory)
        let kept = UUID()
        let dropped = UUID()
        let png = try tinyPNG()
        try successVoid(library.installPreparedPNG(png, forBookmark: kept))
        try successVoid(library.installPreparedPNG(png, forBookmark: dropped))
        let removed = try XCTUnwrap(library.bookmarkIconURL(id: dropped))
        library.pruneBookmarks(keeping: [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertNotNil(library.bookmarkIconURL(id: kept))
        XCTAssertNil(library.bookmarkIconURL(id: dropped))
    }

    func testInstallRejectsNonPNGBytes() {
        let library = IconLibrary(directory: directory)
        let svg = Data("<svg></svg>".utf8)
        XCTAssertEqual(failure(library.installPreparedPNG(svg, forBookmark: UUID())), .unsupportedType)
        XCTAssertEqual(failure(library.installPreparedPNG(Data(), forHost: "example.com")), .empty)
        XCTAssertEqual(failure(library.installPreparedPNG(try! tinyPNG(), forHost: " ")), .invalidHost)
        XCTAssertEqual(
            failure(library.installPreparedPNG(pngHeader(width: 2000, height: 2000), forBookmark: UUID())),
            .absurdDimensions
        )
    }

    func testStoredSymlinkAndHugePNGAreIgnored() throws {
        let library = IconLibrary(directory: directory)
        let png = try tinyPNG()
        try successVoid(library.installPreparedPNGForAppIcon(png))
        let stored = try XCTUnwrap(library.customAppIconURL())
        let outside = directory.appendingPathComponent("outside.png")
        try png.write(to: outside)
        try FileManager.default.removeItem(at: stored)
        try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: outside)
        XCTAssertNil(library.customAppIconURL())

        try FileManager.default.removeItem(at: stored)
        try pngHeader(width: 16_384, height: 16_384).write(to: stored)
        XCTAssertNil(library.customAppIconURL())
    }

    func testResetDoesNotDeletePlantedDirectory() throws {
        let library = IconLibrary(directory: directory)
        let png = try tinyPNG()
        try successVoid(library.installPreparedPNGForAppIcon(png))
        let stored = try XCTUnwrap(library.customAppIconURL())
        try FileManager.default.removeItem(at: stored)
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        let nested = stored.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: nested)
        try successVoid(library.resetAppIcon())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), "keep")
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    func testSanitizedPNGAcceptsTinyPNGAndDownscales() throws {
        let tiny = try tinyPNG()
        let encoded = try successData(IconUpload.sanitizedPNG(data: tiny, fileExtension: "png"))
        XCTAssertEqual(IconUpload.detectedKind(data: encoded), .png)
        let tinySize = try imageSize(encoded)
        XCTAssertEqual(tinySize.width, 1)
        XCTAssertEqual(tinySize.height, 1)

        let wide = try makePNG(width: 600, height: 200)
        let scaled = try successData(IconUpload.sanitizedPNG(data: wide, fileExtension: "png"))
        let size = try imageSize(scaled)
        let expected = try XCTUnwrap(IconUpload.scaledSize(width: 600, height: 200))
        XCTAssertLessThanOrEqual(size.width, IconUpload.maxEdge)
        XCTAssertLessThanOrEqual(size.height, IconUpload.maxEdge)
        XCTAssertEqual(max(size.width, size.height), IconUpload.maxEdge)
        // ImageIO's other side can differ by a pixel from the pure rounding in scaledSize.
        XCTAssertLessThanOrEqual(abs(size.width - expected.width), 2)
        XCTAssertLessThanOrEqual(abs(size.height - expected.height), 2)
    }

    func testSanitizedPNGKeepsEXIFRotationForSmallImages() throws {
        // 300x200 stored, orientation 6 (rotate 90° clockwise to display): shows as 200x300.
        let jpeg = try makeImageData(width: 300, height: 200, type: "public.jpeg", orientation: 6)
        let encoded = try successData(IconUpload.sanitizedPNG(data: jpeg, fileExtension: "jpg"))
        let size = try imageSize(encoded)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 300)
    }
    #endif

    /// Signature plus a well-formed IHDR. Enough for `pngPixelSize`; not a complete image.
    private func pngHeader(width: Int, height: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: Array("IHDR".utf8))
        func appendBE(_ value: Int) {
            let v = UInt32(value)
            data.append(UInt8((v >> 24) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8(v & 0xFF))
        }
        appendBE(width)
        appendBE(height)
        data.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }

    private func tinyPNG() throws -> Data {
        let hex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63f8cfc0f01f00050001ff89993d1d0000000049454e44ae426082"
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw CocoaError(.coderReadCorrupt)
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private func permission(_ url: URL) -> Int {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { return -1 }
        return Int(mode_t(info.st_mode) & 0o777)
    }

    private func failure<T>(_ result: Result<T, IconUploadError>) -> IconUploadError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func successKind(_ result: Result<IconFileKind, IconUploadError>) throws -> IconFileKind {
        switch result {
        case .success(let kind):
            return kind
        case .failure(let error):
            XCTFail("unexpected \(error.rawValue)")
            throw error
        }
    }

    private func successVoid(_ result: Result<Void, IconUploadError>) throws {
        if case .failure(let error) = result {
            XCTFail("unexpected \(error.rawValue)")
            throw error
        }
    }

    private func successString(_ result: Result<String, IconUploadError>) throws -> String {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("unexpected \(error.rawValue)")
            throw error
        }
    }

    private func successData(_ result: Result<Data, IconUploadError>) throws -> Data {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("unexpected \(error.rawValue)")
            throw error
        }
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private func makePNG(width: Int, height: Int) throws -> Data {
        try makeImageData(width: width, height: height, type: "public.png", orientation: nil)
    }

    private func makeImageData(width: Int, height: Int, type: String, orientation: Int?) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.coderReadCorrupt)
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw CocoaError(.coderReadCorrupt)
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, type as CFString, 1, nil) else {
            throw CocoaError(.coderReadCorrupt)
        }
        if let orientation {
            let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return buffer as Data
    }

    private func imageSize(_ data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height else {
            throw CocoaError(.coderReadCorrupt)
        }
        return (width, height)
    }
    #endif
}
