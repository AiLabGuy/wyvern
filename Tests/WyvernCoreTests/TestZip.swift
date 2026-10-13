// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One stored (uncompressed) zip member for tests.
struct TestZipEntry {
    var name: String
    var data: Data
    var unixMode: UInt32 = 0o100644
    var flags: UInt16 = 0
    /// Name written into the local header when it should differ from the central record.
    var localName: String?

    init(_ name: String, _ data: Data, unixMode: UInt32 = 0o100644, flags: UInt16 = 0, localName: String? = nil) {
        self.name = name
        self.data = data
        self.unixMode = unixMode
        self.flags = flags
        self.localName = localName
    }
}

/// Minimal zip writer: stored entries, Unix modes, real CRC-32. Output extracts with ditto and unzip.
enum TestZip {
    static func build(_ entries: [TestZipEntry], prefix: Data = Data()) -> Data {
        var out = prefix
        var central = Data()
        for entry in entries {
            let offset = UInt32(out.count)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            append32(&out, 0x0403_4b50)
            append16(&out, 20)
            append16(&out, entry.flags)
            append16(&out, 0)
            append16(&out, 0)
            append16(&out, 0x0021)
            append32(&out, crc)
            append32(&out, size)
            append32(&out, size)
            append16(&out, UInt16(localName.count))
            append16(&out, 0)
            out.append(localName)
            out.append(entry.data)

            append32(&central, 0x0201_4b50)
            append16(&central, 0x031E)
            append16(&central, 20)
            append16(&central, entry.flags)
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0x0021)
            append32(&central, crc)
            append32(&central, size)
            append32(&central, size)
            append16(&central, UInt16(name.count))
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append32(&central, entry.unixMode << 16)
            append32(&central, offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        append32(&out, 0x0605_4b50)
        append16(&out, 0)
        append16(&out, 0)
        append16(&out, UInt16(entries.count))
        append16(&out, UInt16(entries.count))
        append32(&out, UInt32(central.count))
        append32(&out, centralOffset)
        append16(&out, 0)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func append16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
