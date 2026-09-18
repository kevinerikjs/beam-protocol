import Foundation

// Every multi-byte integer on the wire is big-endian. These two helpers are
// the only place the package touches raw memory, and they are correct for
// `Data` slices, whose indices do not start at zero.

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Reads a big-endian integer at absolute index `index`. The caller has
    /// already checked that `MemoryLayout<T>.size` bytes are available.
    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at index: Index) -> T {
        self[index..<index + MemoryLayout<T>.size].withUnsafeBytes {
            $0.loadUnaligned(as: T.self).bigEndian
        }
    }
}
