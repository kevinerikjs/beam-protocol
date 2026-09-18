import Foundation

/// Conversions between the two ways H.264 and HEVC bitstreams delimit NAL
/// units.
///
/// The wire carries **Annex B**: each NAL unit preceded by the start code
/// `00 00 00 01`. VideoToolbox produces and consumes **AVCC/HVCC**: each NAL
/// unit preceded by its four-byte big-endian length. Neither side of a Phoros
/// link touches the NAL bytes themselves; only the delimiters change.
public enum AnnexB {
    public static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// The NAL units in an Annex B buffer, without start codes.
    public static func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        forEachNALUnit(in: data) { units.append(Data($0)) }
        return units
    }

    /// Annex B to length-prefixed. Empty input gives empty output.
    public static func toLengthPrefixed(_ annexB: Data) -> Data {
        var out = Data(capacity: annexB.count)
        forEachNALUnit(in: annexB) { unit in
            var length = UInt32(unit.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    /// Length-prefixed to Annex B. Stops at the first length that overruns the
    /// buffer.
    public static func fromLengthPrefixed(_ avcc: Data) -> Data {
        var out = Data(capacity: avcc.count + 16)
        var offset = avcc.startIndex
        while offset + 4 <= avcc.endIndex {
            let length = Int(avcc[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            offset += 4
            guard length > 0, offset + length <= avcc.endIndex else { break }
            out.append(startCode)
            out.append(avcc[offset..<offset + length])
            offset += length
        }
        return out
    }

    /// Wraps each NAL unit with a start code.
    public static func join(_ nalUnits: [Data]) -> Data {
        var out = Data()
        for unit in nalUnits {
            out.append(startCode)
            out.append(unit)
        }
        return out
    }

    private static func forEachNALUnit(in data: Data, _ body: (Data.SubSequence) -> Void) {
        let end = data.endIndex
        var index = data.startIndex
        // Find the first start code.
        guard let firstStart = nextStartCode(in: data, from: index) else { return }
        index = firstStart + 4
        while index <= end {
            let next = nextStartCode(in: data, from: index) ?? end
            if next > index { body(data[index..<next]) }
            if next == end { break }
            index = next + 4
        }
    }

    private static func nextStartCode(in data: Data, from start: Data.Index) -> Data.Index? {
        var index = start
        let end = data.endIndex
        while index + 4 <= end {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 0, data[index + 3] == 1 {
                return index
            }
            index += 1
        }
        return nil
    }
}
