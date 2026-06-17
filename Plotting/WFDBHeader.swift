//
//  WFDBHeader.swift
//  Plotting
//
//  Parses a PhysioNet WFDB record header (.hea) text file into a typed value.
//  Supported formats: 16 (16-bit little-endian) and 212 (12-bit packed).
//
//  Reference: https://physionet.org/physiotools/wag/header-5.htm
//
//  .hea format:
//    Line 1 (record line):  <name> <n_signals> <fs>[/<counter_fs>] [<n_samples>] [<time> <date>]
//    Lines 2…n (signal lines, one per signal):
//        <filename> <format> [<gain>[(<unit>)][/<baseline>]] [<adc_res>] [<adc_zero>]
//        [<first_val>] [<checksum>] [<blocksize>] [<description>…]
//

import Foundation

struct WFDBHeader: Equatable, Sendable {
    let recordName: String
    let signalCount: Int
    let samplingFrequency: Double
    let sampleCount: Int64          // samples per signal (= frames); 0 if unspecified
    let startDate: Date?
    let signals: [WFDBSignal]
}

struct WFDBSignal: Equatable, Sendable {
    let filename: String            // relative path to the .dat file
    let format: Int                 // 16 or 212
    let gain: Double                // ADC units per physical unit (e.g. 200 for 200 LSB/mV)
    let unit: String                // physical unit string (e.g. "mV")
    let baseline: Int               // ADC value that equals 0 physical units
                                    // (defaults to adcZero per WFDB spec)
    let adcResolution: Int          // bit depth (e.g. 12 or 16)
    let adcZero: Int                // ADC value for 0 input voltage
    let label: String               // signal label (e.g. "I", "II", "V1", "aVR")
}

enum WFDBHeaderError: LocalizedError {
    case emptyFile
    case malformedRecordLine(String)
    case unsupportedFormat(Int, signal: String)
    case signalCountMismatch(expected: Int, actual: Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The header file is empty."
        case .malformedRecordLine(let line):
            return "Malformed record line: \"\(line)\"."
        case .unsupportedFormat(let fmt, let signal):
            return "Signal \"\(signal)\" uses format \(fmt); only formats 16 and 212 are supported."
        case .signalCountMismatch(let expected, let actual):
            return "Header declares \(expected) signals but contains \(actual) signal lines."
        case .unreadable:
            return "Could not read the header file as UTF-8 text."
        }
    }
}

enum WFDBHeaderParser {

    static func parse(url: URL) throws -> WFDBHeader {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WFDBHeaderError.unreadable
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> WFDBHeader {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { throw WFDBHeaderError.emptyFile }

        let (record, startDate) = try parseRecordLine(lines[0])
        let signalLines = Array(lines.dropFirst())

        if record.signalCount > 0 && signalLines.count != record.signalCount {
            throw WFDBHeaderError.signalCountMismatch(
                expected: record.signalCount,
                actual: signalLines.count
            )
        }

        let signals = try signalLines.map { try parseSignalLine($0) }
        return WFDBHeader(
            recordName: record.recordName,
            signalCount: record.signalCount,
            samplingFrequency: record.samplingFrequency,
            sampleCount: record.sampleCount,
            startDate: startDate,
            signals: signals
        )
    }

    // MARK: - Private parsing

    private struct RecordFields {
        let recordName: String
        let signalCount: Int
        let samplingFrequency: Double
        let sampleCount: Int64
    }

    private static func parseRecordLine(_ line: String) throws -> (RecordFields, Date?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let signalCount = Int(parts[1]) else {
            throw WFDBHeaderError.malformedRecordLine(line)
        }

        let recordName = parts[0]

        // Sampling frequency may include a counter frequency: "360/60" — take the base
        var samplingFrequency = 250.0
        if parts.count >= 3 {
            let freqStr = parts[2].components(separatedBy: "/")[0]
            samplingFrequency = Double(freqStr) ?? 250.0
        }

        var sampleCount: Int64 = 0
        if parts.count >= 4 { sampleCount = Int64(parts[3]) ?? 0 }

        var startDate: Date?
        if parts.count >= 5 {
            let datePart = parts.count >= 6 ? parts[5] : nil
            startDate = parseDateTime(time: parts[4], date: datePart)
        }

        return (RecordFields(
            recordName: recordName,
            signalCount: signalCount,
            samplingFrequency: samplingFrequency,
            sampleCount: sampleCount
        ), startDate)
    }

    private static func parseSignalLine(_ line: String) throws -> WFDBSignal {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { throw WFDBHeaderError.malformedRecordLine(line) }

        let filename = parts[0]

        // Format field may carry a samples-per-frame suffix: "16x2". Extract the numeric prefix.
        let formatStr = parts[1].components(separatedBy: CharacterSet(charactersIn: "x:+"))[0]
        guard let format = Int(formatStr), (format == 16 || format == 212) else {
            let fmt = Int(formatStr) ?? -1
            throw WFDBHeaderError.unsupportedFormat(fmt, signal: filename)
        }

        var gain = 200.0
        var unit = "mV"
        var explicitBaseline: Int?      // nil = not specified; defaults to adcZero per spec

        if parts.count >= 3 {
            (gain, unit, explicitBaseline) = parseGainField(parts[2])
        }

        let adcResolution = parts.count >= 4 ? (Int(parts[3]) ?? 16) : 16
        let adcZero       = parts.count >= 5 ? (Int(parts[4]) ?? 0)  : 0

        // Per WFDB spec: baseline defaults to adcZero if not explicitly given.
        let baseline = explicitBaseline ?? adcZero

        // Standard WFDB field layout (0-based):
        //   0=filename  1=format  2=gain  3=adcres  4=adczero  5=firstval  6=checksum  7=blocksize  8+=description
        let label: String
        if parts.count >= 9 {
            label = parts[8...].joined(separator: " ")
        } else {
            label = parts.last ?? filename
        }

        return WFDBSignal(
            filename: filename,
            format: format,
            gain: gain,
            unit: unit,
            baseline: baseline,
            adcResolution: adcResolution,
            adcZero: adcZero,
            label: label
        )
    }

    /// Parses the gain field which takes forms like:
    ///   "200", "200(mV)", "200(mV)/0", "1000(mV)/1000"
    /// Returns `nil` for baseline when the "/" suffix is absent (caller uses adcZero as default).
    private static func parseGainField(_ field: String) -> (gain: Double, unit: String, baseline: Int?) {
        var rest = field

        var baseline: Int?
        if let slashIdx = rest.firstIndex(of: "/") {
            baseline = Int(String(rest[rest.index(after: slashIdx)...])) ?? 0
            rest = String(rest[..<slashIdx])
        }

        var unit = "mV"
        if let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") {
            unit = String(rest[rest.index(after: open)..<close])
            rest = String(rest[..<open])
        }

        let gain = Double(rest) ?? 200.0
        return (gain, unit, baseline)
    }

    /// Parses an optional start time/date from the record line.
    /// Time: "hh:mm:ss[.mmm]"   Date: "dd/mm/yyyy"
    private static func parseDateTime(time: String, date: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let dateStr = date {
            formatter.dateFormat = "HH:mm:ss dd/MM/yyyy"
            return formatter.date(from: "\(time) \(dateStr)")
        }
        return nil
    }
}
