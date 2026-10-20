// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

/// Kinds an untrusted icon upload may be. Anything else is rejected.
public enum IconFileKind: String, Equatable, Sendable {
    case png
    case jpeg
    case icns
    case heic
}

public enum IconUploadError: String, Equatable, Error, Sendable {
    case empty
    case tooLarge
    case unsupportedType
    case extensionMismatch
    case decodeFailed
    case absurdDimensions
    case imageIOUnavailable
    case unreadable
    case writeFailed
    case invalidHost
}

/// Bytes read from a regular file after the size cap was checked.
public struct IconFilePayload: Equatable, Sendable {
    public var data: Data
    public var fileExtension: String
    public var typeIdentifier: String?

    public init(data: Data, fileExtension: String, typeIdentifier: String?) {
        self.data = data
        self.fileExtension = fileExtension
        self.typeIdentifier = typeIdentifier
    }
}

/// Strict checks for an icon the user picked. Callers must not trust the name.
///
/// A file is accepted only when all of these hold:
/// - It is a regular file, not a symbolic link (`O_NOFOLLOW`).
/// - Its size is at most 5 MiB. The size is taken from `fstat` before the bytes
///   are read, and checked again on the buffer that was read.
/// - The extension, when present, is `png`, `jpg`/`jpeg`/`jpe`, `icns`, or
///   `heic`/`heif`. A UTType identifier, when present, is `public.png`,
///   `public.jpeg`, `com.apple.icns`, `public.heic`, or `public.heif`
///   (plus `public.jpg` and `public.heif-standard`).
/// - Magic bytes name that same kind. The extension is not trusted on its own.
/// - At least one of the extension or the UTType must name the kind. A valid
///   PNG with a disallowed extension such as `.gif` or `.txt` is rejected
///   (`extensionMismatch`), even though the bytes are a PNG. A `.png` whose
///   bytes are SVG, XML, PDF, or anything else is rejected (`unsupportedType`).
///
/// ImageIO then decodes the file, rejects zero images, a failed decode, or a
/// side of 0 or greater than 4096, scales the longest side to at most 512,
/// and re-encodes PNG. Stored names are chosen by the library, never by the user.
/// 4096 is enough for a 4K source and caps an uncompressed bitmap at 64 MiB;
/// ImageIO's thumbnail path may still expand the declared PNG before scaling.
public enum IconUpload {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxDimension = 4_096
    public static let maxEdge = 512

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let heifBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "heif", "mif1", "msf1", "hevm", "hevs"
    ]

    public static func kind(forFileExtension ext: String) -> IconFileKind? {
        switch ext.lowercased() {
        case "png":
            return .png
        case "jpg", "jpeg", "jpe":
            return .jpeg
        case "icns":
            return .icns
        case "heic", "heif":
            return .heic
        default:
            return nil
        }
    }

    public static func kind(forTypeIdentifier identifier: String) -> IconFileKind? {
        switch identifier.lowercased() {
        case "public.png":
            return .png
        case "public.jpeg", "public.jpg":
            return .jpeg
        case "com.apple.icns":
            return .icns
        case "public.heic", "public.heif", "public.heif-standard":
            return .heic
        default:
            return nil
        }
    }

    /// PNG, JPEG, ICNS, or HEIC/HEIF as named by the leading bytes. Markup is never a match.
    public static func detectedKind(data: Data) -> IconFileKind? {
        if looksLikeMarkup(data) {
            return nil
        }
        if hasPrefix(data, pngSignature) {
            return .png
        }
        if data.count >= 3, data[data.startIndex] == 0xFF,
           data[data.index(data.startIndex, offsetBy: 1)] == 0xD8,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xFF {
            return .jpeg
        }
        if hasPrefix(data, [0x69, 0x63, 0x6E, 0x73]) {
            return .icns
        }
        if isHEIF(data) {
            return .heic
        }
        return nil
    }

    /// `width`/`height` from a decoder. Zero is a failed decode. Above 4096 is refused
    /// before the bitmap is expanded.
    public static func rejectedDimension(width: Int, height: Int) -> IconUploadError? {
        if width <= 0 || height <= 0 {
            return .decodeFailed
        }
        if width > maxDimension || height > maxDimension {
            return .absurdDimensions
        }
        return nil
    }

    /// Longest side at most `maxEdge`, rounding down so the result cannot exceed the cap.
    /// Nil when the source dimensions are already rejected.
    public static func scaledSize(width: Int, height: Int, maxEdge: Int = IconUpload.maxEdge) -> (width: Int, height: Int)? {
        if rejectedDimension(width: width, height: height) != nil {
            return nil
        }
        let longest = max(width, height)
        if longest <= maxEdge {
            return (width, height)
        }
        let scale = Double(maxEdge) / Double(longest)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        return (scaledWidth, scaledHeight)
    }

    /// Header and declared-type check. Does not decode pixels.
    /// `declaredByteCount` is the size already observed on the file, so a caller can
    /// reject an oversize file without handing the whole buffer in.
    public static func validate(
        data: Data,
        fileExtension: String,
        typeIdentifier: String? = nil,
        declaredByteCount: Int64? = nil
    ) -> Result<IconFileKind, IconUploadError> {
        if let declaredByteCount {
            if declaredByteCount <= 0 {
                return .failure(.empty)
            }
            if declaredByteCount > Int64(maxBytes) {
                return .failure(.tooLarge)
            }
        }
        if data.isEmpty {
            return .failure(.empty)
        }
        if data.count > maxBytes {
            return .failure(.tooLarge)
        }
        let trimmedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = typeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensionKind = trimmedExtension.isEmpty ? nil : kind(forFileExtension: trimmedExtension)
        if !trimmedExtension.isEmpty && extensionKind == nil {
            return .failure(.extensionMismatch)
        }
        let typeKind: IconFileKind?
        if let trimmedType, !trimmedType.isEmpty {
            guard let mapped = kind(forTypeIdentifier: trimmedType) else {
                return .failure(.extensionMismatch)
            }
            typeKind = mapped
        } else {
            typeKind = nil
        }
        guard let magic = detectedKind(data: data) else {
            return .failure(.unsupportedType)
        }
        if let extensionKind, extensionKind != magic {
            return .failure(.extensionMismatch)
        }
        if let typeKind, typeKind != magic {
            return .failure(.extensionMismatch)
        }
        if extensionKind == nil && typeKind == nil {
            return .failure(.extensionMismatch)
        }
        return .success(magic)
    }

    /// `fstat` the file, refuse anything over 5 MiB or not a regular file, then read.
    /// Symbolic links are refused (`O_NOFOLLOW`) so the size check cannot see a short
    /// link and then follow it to a larger file. `O_NONBLOCK` keeps a FIFO from blocking
    /// `open` until a writer appears; it is then refused as not a regular file.
    public static func readBounded(at url: URL) -> Result<IconFilePayload, IconUploadError> {
        let opened = url.path.withCString { path -> Int32 in
            #if canImport(Darwin)
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            #else
            return Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            #endif
        }
        if opened < 0 {
            return .failure(.unreadable)
        }
        defer { _ = close(opened) }
        var info = stat()
        if fstat(opened, &info) != 0 {
            return .failure(.unreadable)
        }
        if mode_t(info.st_mode) & S_IFMT != S_IFREG {
            return .failure(.unreadable)
        }
        let count = Int64(info.st_size)
        if count <= 0 {
            return .failure(.empty)
        }
        if count > Int64(maxBytes) {
            return .failure(.tooLarge)
        }
        let byteCount = Int(count)
        var buffer = Data(count: byteCount)
        var offset = 0
        let readOK: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            while offset < byteCount {
                let pointer = base.advanced(by: offset)
                let chunk: Int
                #if canImport(Darwin)
                chunk = Darwin.read(opened, pointer, byteCount - offset)
                #else
                chunk = Glibc.read(opened, pointer, byteCount - offset)
                #endif
                if chunk < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                if chunk == 0 {
                    return false
                }
                offset += chunk
            }
            return true
        }
        if !readOK || buffer.count > maxBytes {
            return readOK ? .failure(.tooLarge) : .failure(.unreadable)
        }
        let typeIdentifier = contentTypeIdentifier(url)
        return .success(IconFilePayload(
            data: buffer,
            fileExtension: url.pathExtension,
            typeIdentifier: typeIdentifier
        ))
    }

    /// Validate, decode, scale, and re-encode to PNG.
    public static func sanitizedPNG(
        data: Data,
        fileExtension: String,
        typeIdentifier: String? = nil
    ) -> Result<Data, IconUploadError> {
        switch validate(data: data, fileExtension: fileExtension, typeIdentifier: typeIdentifier) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        return reencode(data)
        #else
        return .failure(.imageIOUnavailable)
        #endif
    }

    /// Read with the size cap, then sanitize. This is the upload entry point.
    public static func preparedPNG(from url: URL) -> Result<Data, IconUploadError> {
        switch readBounded(at: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let payload):
            return sanitizedPNG(
                data: payload.data,
                fileExtension: payload.fileExtension,
                typeIdentifier: payload.typeIdentifier
            )
        }
    }

    /// IHDR width and height. Nil when the bytes are not a PNG with a leading IHDR.
    public static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, hasPrefix(data, pngSignature) else { return nil }
        func be32(_ offset: Int) -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            let start = data.index(data.startIndex, offsetBy: offset)
            let b0 = UInt32(data[start])
            let b1 = UInt32(data[data.index(start, offsetBy: 1)])
            let b2 = UInt32(data[data.index(start, offsetBy: 2)])
            let b3 = UInt32(data[data.index(start, offsetBy: 3)])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        guard let length = be32(8), length == 13 else { return nil }
        let typeStart = data.index(data.startIndex, offsetBy: 12)
        let typeEnd = data.index(typeStart, offsetBy: 4)
        guard [UInt8](data[typeStart..<typeEnd]) == [0x49, 0x48, 0x44, 0x52] else { return nil }
        guard let width = be32(16), let height = be32(20) else { return nil }
        guard width <= UInt32(Int.max), height <= UInt32(Int.max) else { return nil }
        return (Int(width), Int(height))
    }

    /// True when `data` is a PNG whose IHDR fits in the stored-icon cap (`maxEdge`).
    /// Used for files already on disk and for `installPreparedPNG`, which must not
    /// write a decompression-bomb PNG that skipped `sanitizedPNG`.
    public static func isAcceptableStoredPNG(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes, detectedKind(data: data) == .png else {
            return false
        }
        guard let size = pngPixelSize(data) else { return false }
        if rejectedDimension(width: size.width, height: size.height) != nil {
            return false
        }
        return size.width <= maxEdge && size.height <= maxEdge
    }

    /// `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX.png`, the only name the library will open.
    public static func isStoredFileName(_ name: String) -> Bool {
        guard name.count == 40, name.hasSuffix(".png") else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("..") {
            return false
        }
        let stem = String(name.dropLast(4))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        let expected = [8, 4, 4, 4, 12]
        guard parts.count == expected.count else { return false }
        for (part, length) in zip(parts, expected) {
            guard part.count == length else { return false }
            guard part.allSatisfy({ character in
                character.isHexDigit
            }) else { return false }
        }
        return UUID(uuidString: stem) != nil
    }

    private static func contentTypeIdentifier(_ url: URL) -> String? {
        #if canImport(UniformTypeIdentifiers)
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let identifier = values.contentType?.identifier,
           !identifier.isEmpty {
            return identifier
        }
        #endif
        return nil
    }

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else { return false }
        for (offset, byte) in bytes.enumerated() {
            if data[data.index(data.startIndex, offsetBy: offset)] != byte {
                return false
            }
        }
        return true
    }

    private static func looksLikeMarkup(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(256))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), bytes.count >= 3 {
            bytes.removeFirst(3)
        }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes.removeFirst()
        }
        let head = Data(bytes.prefix(64))
        guard let text = String(data: head, encoding: .utf8)?.lowercased() else {
            return false
        }
        return text.hasPrefix("<svg")
            || text.hasPrefix("<?xml")
            || text.hasPrefix("<!doctype")
            || text.hasPrefix("<html")
            || text.hasPrefix("%pdf")
    }

    private static func isHEIF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp: [UInt8] = [0x66, 0x74, 0x79, 0x70]
        for (offset, byte) in ftyp.enumerated() {
            if data[data.index(data.startIndex, offsetBy: offset + 4)] != byte {
                return false
            }
        }
        let brandStart = data.index(data.startIndex, offsetBy: 8)
        let brandEnd = data.index(brandStart, offsetBy: 4)
        guard let brand = String(data: data[brandStart..<brandEnd], encoding: .ascii) else {
            return false
        }
        return heifBrands.contains(brand)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private static func reencode(_ data: Data) -> Result<Data, IconUploadError> {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return .failure(.decodeFailed)
        }
        let count = CGImageSourceGetCount(source)
        if count <= 0 {
            return .failure(.decodeFailed)
        }
        var bestIndex = -1
        var bestEdge = -1
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                sourceOptions as CFDictionary
            ) as? [CFString: Any] else {
                return .failure(.decodeFailed)
            }
            guard let width = intProperty(properties[kCGImagePropertyPixelWidth]),
                  let height = intProperty(properties[kCGImagePropertyPixelHeight]) else {
                return .failure(.decodeFailed)
            }
            if let error = rejectedDimension(width: width, height: height) {
                return .failure(error)
            }
            let edge = max(width, height)
            if edge > bestEdge {
                bestEdge = edge
                bestIndex = index
            }
        }
        guard bestIndex >= 0 else {
            return .failure(.decodeFailed)
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, bestIndex, options as CFDictionary) {
            // Compare the longest side: an EXIF rotation swaps width and height without growing.
            let grew = max(thumbnail.width, thumbnail.height) > bestEdge
            if grew == false {
                return encodePNG(thumbnail)
            }
        }
        if bestEdge <= maxEdge,
           let image = CGImageSourceCreateImageAtIndex(source, bestIndex, sourceOptions as CFDictionary) {
            return encodePNG(image)
        }
        return .failure(.decodeFailed)
    }

    private static func intProperty(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func encodePNG(_ image: CGImage) -> Result<Data, IconUploadError> {
        if image.width <= 0 || image.height <= 0 || image.width > maxEdge || image.height > maxEdge {
            return .failure(.decodeFailed)
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else {
            return .failure(.decodeFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(.decodeFailed)
        }
        let encoded = buffer as Data
        if encoded.isEmpty || encoded.count > maxBytes || detectedKind(data: encoded) != .png {
            return .failure(.decodeFailed)
        }
        return .success(encoded)
    }
    #endif
}

/// Host key for a per-site tab icon.
///
/// The host is lowercased the same way `SitePermissionPolicy.originKey` lowercases it.
/// A non-default port is kept (`example.com:8443`); port 80 on http and 443 on https
/// are omitted. The scheme is not part of the key: tab icons are matched by host, and
/// the tab strip looks the host up from the page URL. A leading `www.` is kept, matching
/// origin keys. A pasted URL contributes its host only.
public enum IconHostKey {
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300 else { return nil }
        guard trimmed.contains(where: { $0.isWhitespace }) == false else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { return nil }
            return normalize(url: url)
        }
        guard let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty else {
            return nil
        }
        let port = url.port ?? 0
        if port == 0 || port == 80 || port == 443 {
            return cleanHost(host)
        }
        guard let name = cleanHost(host) else { return nil }
        return "\(name):\(port)"
    }

    public static func normalize(url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        guard let name = cleanHost(host) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? 0
        let omitPort = port == 0
            || (scheme == "http" && port == 80)
            || (scheme == "https" && port == 443)
            || (scheme != "http" && scheme != "https" && (port == 80 || port == 443))
        if omitPort {
            return name
        }
        return "\(name):\(port)"
    }

    private static func cleanHost(_ host: String) -> String? {
        var name = host.lowercased()
        while name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty, name.count <= 253 else { return nil }
        guard name.contains("/") == false, name.contains(" ") == false else { return nil }
        return name
    }
}
