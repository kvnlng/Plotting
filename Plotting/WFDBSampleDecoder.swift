//
//  WFDBSampleDecoder.swift
//  Plotting
//
//  Decodes PhysioNet WFDB format-16 and format-212 (.dat) binary data into
//  physical Float32 samples.
//
//  Format 16:
//    • Each sample is a 16-bit signed integer in little-endian byte order.
//    • Samples are interleaved across signals: frame[sig0, sig1, …]
//    • Total bytes = signalCount × sampleCount × 2
//
//  Format 212:
//    • Two adjacent 12-bit samples share 3 bytes.
//    • Byte layout for a pair (A, B):
//        byte[0] = A[7:0]
//        byte[1] = B[3:0]<<4 | A[11:8]
//        byte[2] = B[11:4]
//    • Samples are laid out sequentially across the entire file (interleaved by
//      frame), then packed 2-at-a-time. For N signals × S frames the flat
//      sequence is [f0s0, f0s1, …, f0sN-1, f1s0, …] with length N×S.
//    • Total bytes = ceil(N × S / 2) × 3
//
//  Physical conversion: physicalValue = (adcSample − signal.baseline) / signal.gain
//

import Foundation

enum WFDBDecodeError: LocalizedError {
    case unreadable(URL)
    case truncatedFile(expectedBytes: Int, actualBytes: Int)
    case multipleDataFiles
    case mixedFormats

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read sample file: \(url.lastPathComponent)."
        case .truncatedFile(let expected, let actual):
            return "Sample file is truncated: expected \(expected) bytes, found \(actual)."
        case .multipleDataFiles:
            return "Records that reference multiple .dat files are not supported."
        case .mixedFormats:
            return "All signals in a record must use the same storage format."
        }
    }
}

enum WFDBSampleDecoder {

    static func decode(datURL: URL, header: WFDBHeader) throws -> [[Float]] {
        guard Set(header.signals.map(\.filename)).count <= 1 else {
            throw WFDBDecodeError.multipleDataFiles
        }
        let formats = Set(header.signals.map(\.format))
        guard formats.count <= 1 else { throw WFDBDecodeError.mixedFormats }

        let needsScope = datURL.startAccessingSecurityScopedResource()
        defer { if needsScope { datURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: datURL, options: [.mappedIfSafe]) else {
            throw WFDBDecodeError.unreadable(datURL)
        }

        let format = header.signals.first?.format ?? 16
        if format == 212 {
            return try decodeFormat212(data: data, signals: header.signals, declaredSampleCount: header.sampleCount)
        } else {
            return try decodeFormat16(data: data, signals: header.signals, declaredSampleCount: header.sampleCount)
        }
    }

    // MARK: - Format 16

    /// Pure-data variant used by tests — no file I/O.
    static func decode(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let formats = Set(signals.map(\.format))
        guard formats.count <= 1 else { throw WFDBDecodeError.mixedFormats }
        let format = signals.first?.format ?? 16
        if format == 212 {
            return try decodeFormat212(data: data, signals: signals, declaredSampleCount: declaredSampleCount)
        } else {
            return try decodeFormat16(data: data, signals: signals, declaredSampleCount: declaredSampleCount)
        }
    }

    static func decodeFormat16(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let signalCount = signals.count
        guard signalCount > 0 else { return [] }

        let frameSize = signalCount * 2

        let sampleCount: Int
        if declaredSampleCount > 0 {
            let expectedBytes = Int(declaredSampleCount) * frameSize
            guard data.count >= expectedBytes else {
                throw WFDBDecodeError.truncatedFile(expectedBytes: expectedBytes, actualBytes: data.count)
            }
            sampleCount = Int(declaredSampleCount)
        } else {
            sampleCount = data.count / frameSize
        }

        var output = [[Float]](
            repeating: [Float](repeating: 0, count: sampleCount),
            count: signalCount
        )

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let int16Base = base.assumingMemoryBound(to: Int16.self)
            for sampleIdx in 0..<sampleCount {
                for signalIdx in 0..<signalCount {
                    let frameOffset = sampleIdx * signalCount + signalIdx
                    let adcValue = Int(Int16(littleEndian: int16Base[frameOffset]))
                    let signal = signals[signalIdx]
                    output[signalIdx][sampleIdx] = Float(adcValue - signal.baseline) / Float(signal.gain)
                }
            }
        }

        return output
    }

    // MARK: - Format 212

    static func decodeFormat212(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let signalCount = signals.count
        guard signalCount > 0 else { return [] }

        // Total samples in the interleaved flat sequence = signalCount × sampleCount.
        let sampleCount: Int
        if declaredSampleCount > 0 {
            sampleCount = Int(declaredSampleCount)
        } else {
            // Each group of 3 bytes holds 2 12-bit samples.
            sampleCount = (data.count / 3 * 2) / signalCount
        }

        let totalFlat     = signalCount * sampleCount
        let requiredBytes = (totalFlat + 1) / 2 * 3    // ceil(totalFlat / 2) × 3
        guard data.count >= requiredBytes else {
            throw WFDBDecodeError.truncatedFile(expectedBytes: requiredBytes, actualBytes: data.count)
        }

        // Unpack the entire flat sequence of 12-bit two's-complement integers.
        var flat = [Int32](repeating: 0, count: totalFlat)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var flatIdx = 0
            var byteIdx = 0
            while flatIdx + 1 <= totalFlat - 1 {
                let b0 = UInt16(bytes[byteIdx])
                let b1 = UInt16(bytes[byteIdx + 1])
                let b2 = UInt16(bytes[byteIdx + 2])

                let rawA = b0 | ((b1 & 0x0F) << 8)     // A: byte[0] + low nibble of byte[1]
                let rawB = (b2 << 4) | (b1 >> 4)        // B: byte[2] + high nibble of byte[1]

                // Sign-extend from 12 bits to 16 bits using arithmetic right shift.
                flat[flatIdx]     = Int32(Int16(bitPattern: rawA << 4) >> 4)
                flat[flatIdx + 1] = Int32(Int16(bitPattern: rawB << 4) >> 4)

                flatIdx  += 2
                byteIdx  += 3
            }
            // Odd trailing sample.
            if flatIdx < totalFlat {
                let b0 = UInt16(bytes[byteIdx])
                let b1 = UInt16(bytes[byteIdx + 1])
                let rawA = b0 | ((b1 & 0x0F) << 8)
                flat[flatIdx] = Int32(Int16(bitPattern: rawA << 4) >> 4)
            }
        }

        // Re-arrange from interleaved flat layout into per-signal arrays.
        var output = [[Float]](
            repeating: [Float](repeating: 0, count: sampleCount),
            count: signalCount
        )
        for sampleIdx in 0..<sampleCount {
            for signalIdx in 0..<signalCount {
                let signal = signals[signalIdx]
                let adcValue = Int(flat[sampleIdx * signalCount + signalIdx])
                output[signalIdx][sampleIdx] = Float(adcValue - signal.baseline) / Float(signal.gain)
            }
        }
        return output
    }
}
