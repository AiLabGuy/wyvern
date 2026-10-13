// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Vision

struct FieldCaptureFailure {
    var permissionMissing: Bool
    var detail: String
}

struct FieldImageReport {
    var text: String
    var inkedColumns: Int
    var width: Int
    var fraction: Double
    var hasZZZ: Bool
    var hasLoopback: Bool
    var hasPlain: Bool
}

/// Vertical span of dark pixels. Row 0 is the top of the bitmap.
struct VerticalInkReport {
    var firstRow: Int
    var lastRow: Int
    var inkMidY: Double
    var height: Int
    var inkedRows: Int
}

/// Screen-rectangle capture and the pixel checks for the address field.
enum FieldCapture {
    /// Writes a PNG of `rect` with `screencapture -x -R x,y,w,h`. Nil means the file is readable.
    static func capture(rect: CGRect?, to path: String) -> FieldCaptureFailure? {
        try? FileManager.default.removeItem(atPath: path)
        guard let rect else {
            return FieldCaptureFailure(permissionMissing: false, detail: "address field has no AX frame")
        }
        let preflight = CGPreflightScreenCaptureAccess()
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture") else {
            return FieldCaptureFailure(
                permissionMissing: !preflight,
                detail: "screencapture is missing"
            )
        }
        let x = Int(floor(rect.origin.x))
        let y = Int(floor(rect.origin.y))
        let w = max(1, Int(ceil(rect.maxX)) - x)
        let h = max(1, Int(ceil(rect.maxY)) - y)
        let region = "\(x),\(y),\(w),\(h)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", region, path]
        task.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return FieldCaptureFailure(
                permissionMissing: !preflight,
                detail: "could not run screencapture -x -R \(region)"
            )
        }
        task.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        let bytes = byteCount?.intValue ?? 0
        let loaded = bytes > 32 ? load(path) : nil
        if task.terminationStatus == 0, let loaded, loaded.width >= 8, loaded.height >= 4 {
            return nil
        }
        let trimmed = errText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let denied = !preflight || trimmed.lowercased().contains("not authorized")
            || trimmed.lowercased().contains("permission")
        var detail = "screencapture -x -R \(region) status \(task.terminationStatus) bytes \(bytes)"
        if !trimmed.isEmpty {
            detail += " \(trimmed)"
        }
        return FieldCaptureFailure(permissionMissing: denied, detail: detail)
    }

    /// Dark-pixel rows in the capture. The midpoint is compared with the image midpoint.
    static func verticalInk(path: String) -> Result<VerticalInkReport, String> {
        guard let image = load(path) else {
            return .failure("could not read capture")
        }
        return .success(inkRows(image))
    }

    static func analyze(path: String) -> Result<FieldImageReport, String> {
        guard let image = load(path) else {
            return .failure("could not read capture")
        }
        let ink = inkColumns(image)
        let text = recognize(scaled(image, factor: 4) ?? image)
        let folded = text.lowercased().filter { !$0.isWhitespace }
        return .success(FieldImageReport(
            text: text,
            inkedColumns: ink.inked,
            width: ink.width,
            fraction: ink.width > 0 ? Double(ink.inked) / Double(ink.width) : 1,
            hasZZZ: folded.contains("zzz"),
            hasLoopback: folded.contains("127.0.0.1"),
            hasPlain: folded.contains("plain")
        ))
    }

    private static func load(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func scaled(_ image: CGImage, factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Width of the dark text, from the first inked column to the last. Light-theme text is
    /// #111111 and the muted tail is #6E6E6E; the field fill is #EDEDED. A still-visible URL
    /// spans most of the field. "zzz" does not.
    private static func inkColumns(_ image: CGImage) -> (inked: Int, width: Int) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return (0, 0) }
        let bytesPerRow = width * 4
        let count = bytesPerRow * height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer { buffer.deallocate() }
        var first = -1
        var last = -1
        if let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for x in 0..<width {
                var hits = 0
                var column = false
                for y in 0..<height {
                    let offset = y * bytesPerRow + x * 4
                    if buffer[offset + 3] < 128 { continue }
                    let luma = (Int(buffer[offset]) * 2126 + Int(buffer[offset + 1]) * 7152 + Int(buffer[offset + 2]) * 722) / 10000
                    if luma < 160 {
                        hits += 1
                        if hits >= 2 {
                            column = true
                            break
                        }
                    }
                }
                if column {
                    if first < 0 { first = x }
                    last = x
                }
            }
        }
        buffer.deinitialize(count: count)
        let inked = first < 0 ? 0 : (last - first + 1)
        return (inked, width)
    }

    /// A row is ink when two pixels are at least as dark as the muted label. Buffer row 0 is the top.
    private static func inkRows(_ image: CGImage) -> VerticalInkReport {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return VerticalInkReport(firstRow: -1, lastRow: -1, inkMidY: 0, height: 0, inkedRows: 0)
        }
        let bytesPerRow = width * 4
        let count = bytesPerRow * height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer { buffer.deallocate() }
        var first = -1
        var last = -1
        var inkedRows = 0
        if let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for y in 0..<height {
                var hits = 0
                var row = false
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    if buffer[offset + 3] < 128 { continue }
                    let luma = (Int(buffer[offset]) * 2126 + Int(buffer[offset + 1]) * 7152 + Int(buffer[offset + 2]) * 722) / 10000
                    if luma < 160 {
                        hits += 1
                        if hits >= 2 {
                            row = true
                            break
                        }
                    }
                }
                if row {
                    if first < 0 { first = y }
                    last = y
                    inkedRows += 1
                }
            }
        }
        buffer.deinitialize(count: count)
        let mid = first < 0 ? 0 : Double(first + last) / 2
        return VerticalInkReport(firstRow: first, lastRow: last, inkMidY: mid, height: height, inkedRows: inkedRows)
    }

    private static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = ["zzz"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

/// Lets capture analysis report a plain message through Result.
extension String: Error {}
