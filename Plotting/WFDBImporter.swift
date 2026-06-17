//
//  WFDBImporter.swift
//  Plotting
//
//  Converts a PhysioNet WFDB record (.hea + .dat) into the internal Recording bundle:
//    <recordingID>/
//      recording.json              — manifest
//      channel_<label>.bin         — packed Float32 raw samples per signal
//      pyramid_<label>_L<n>.bin    — min/max pyramid files
//

import Foundation

enum WFDBImportError: LocalizedError {
    case noSignals
    case missingDatFile(URL)

    var errorDescription: String? {
        switch self {
        case .noSignals:
            return "The header describes no signals."
        case .missingDatFile(let url):
            return "Could not find sample file: \(url.lastPathComponent). It must be in the same folder as the .hea file."
        }
    }
}

enum WFDBImporter {

    /// Imports the WFDB record whose header lives at `heaURL`. The companion .dat file
    /// must be in the same directory. Writes the Recording bundle into a new UUID
    /// subdirectory of `outputDirectory` and returns a summary.
    ///
    /// All CPU work runs synchronously; callers should dispatch to a background task
    /// if calling from the main actor.
    static func importRecord(
        heaURL: URL,
        outputDirectory: URL,
        progress: ImportProgressHandler? = nil
    ) throws -> ImportSummary {
        let needsScope = heaURL.startAccessingSecurityScopedResource()
        defer { if needsScope { heaURL.stopAccessingSecurityScopedResource() } }

        let header = try WFDBHeaderParser.parse(url: heaURL)
        guard !header.signals.isEmpty else { throw WFDBImportError.noSignals }

        // All signals must share the same .dat file (single-file record).
        guard let datFilename = header.signals.first?.filename else { throw WFDBImportError.noSignals }
        let heaDir = heaURL.deletingLastPathComponent()
        let datURL = heaDir.appendingPathComponent(datFilename)

        let needsDatScope = datURL.startAccessingSecurityScopedResource()
        defer { if needsDatScope { datURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: datURL.path) else {
            throw WFDBImportError.missingDatFile(datURL)
        }

        let allSamples = try WFDBSampleDecoder.decode(datURL: datURL, header: header)

        let startDate = header.startDate ?? Date()
        let startMS = Int64(startDate.timeIntervalSince1970 * 1000)

        let recordingID = UUID()
        let directory = outputDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var channels: [Channel] = []
        let totalSignals = header.signals.count
        var grandTotalSamples: Int64 = 0

        for (signalIdx, signal) in header.signals.enumerated() {
            let signalSamples = allSamples[signalIdx]
            let sampleCount = Int64(signalSamples.count)
            grandTotalSamples += sampleCount

            let storageFileName = "channel_\(safeFileName(signal.label)).bin"
            let storageURL = directory.appendingPathComponent(storageFileName)

            let channelHeader = BinaryRecordingHeader(
                version: BinaryRecordingHeader.currentVersion,
                startTimeUnixMS: startMS,
                sampleRateHz: header.samplingFrequency,
                sampleCount: sampleCount
            )
            try BinaryRecordingFile.write(samples: signalSamples, header: channelHeader, to: storageURL)

            let builder = try PyramidBuilder(
                channelName: signal.label,
                baseSampleRate: header.samplingFrequency,
                startTimeUnixMS: startMS,
                directory: directory
            )
            for value in signalSamples { try builder.append(Double(value)) }
            let pyramid = try builder.finalize()

            channels.append(Channel(
                id: UUID(),
                name: signal.label,
                unit: signal.unit,
                sampleRate: header.samplingFrequency,
                startTimeUnixMS: startMS,
                sampleCount: sampleCount,
                storageFileName: storageFileName,
                pyramid: pyramid
            ))

            // Report progress as fraction of signals processed.
            let done = Int64(signalIdx + 1)
            let total = Int64(totalSignals)
            progress?(ImportProgress(bytesRead: done, totalBytes: total))
        }

        let annotations = loadAnnotations(
            recordName: header.recordName,
            in: heaDir,
            recordingStartUnixMS: startMS,
            sampleRate: header.samplingFrequency
        )

        let recording = Recording(
            version: Recording.currentVersion,
            id: recordingID,
            device: header.recordName,
            createdAt: Date(),
            sourceFileName: heaURL.lastPathComponent,
            channels: channels,
            annotations: annotations
        )
        try writeManifest(recording, into: directory)

        return ImportSummary(
            recording: recording,
            directory: directory,
            signalsImported: channels.count,
            totalSamples: grandTotalSamples
        )
    }

    // MARK: - Helpers

    private static func writeManifest(_ recording: Recording, into directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("recording.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recording).write(to: manifestURL, options: .atomic)
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("_") }
            .reduce("") { "\($0)\($1)" }
    }

    /// Scans the record's folder for annotations from two sources, in order:
    ///   1. `<recordName>.annotations.json` — rich findings produced by the
    ///      upstream analysis cluster. This is the canonical path.
    ///   2. `<recordName>.atr` / `.qrs` — WFDB beat marks. Legacy / MIT-BIH
    ///      compatibility path; mapped through the WFDB adapter to point events.
    ///
    /// Both sources can coexist — their annotation lists are concatenated. Any
    /// failure to parse a source is silently ignored: annotations are optional
    /// metadata, never a reason to fail the import.
    private static func loadAnnotations(
        recordName: String,
        in folder: URL,
        recordingStartUnixMS: Int64,
        sampleRate: Double
    ) -> [Annotation] {
        var collected: [Annotation] = []

        // 1. Primary: JSON findings file
        let jsonURL = folder.appendingPathComponent("\(recordName).annotations.json")
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            if let parsed = try? AnnotationLoader.load(
                url: jsonURL,
                recordingStartUnixMS: recordingStartUnixMS,
                sampleRate: sampleRate,
                fallbackSource: recordName
            ) {
                collected.append(contentsOf: parsed)
            }
        }

        // 2. Legacy: WFDB binary annotations
        for ext in ["atr", "qrs"] {
            let url = folder.appendingPathComponent("\(recordName).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let parsed = try? WFDBAnnotationParser.parse(url: url), !parsed.isEmpty {
                collected.append(contentsOf: parsed.map(Annotation.init(fromWFDB:)))
                break
            }
        }

        return collected
    }
}
