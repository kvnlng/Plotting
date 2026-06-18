//
//  SyntheticRecording.swift
//  Plotting
//
//  Generates a minimal WFDB record for UI tests, unit tests, and the welcome
//  screen's "Try a sample recording" affordance.
//
//  Public API:
//    • makeFixture()                       → Recording bundle directory ready
//                                            for `RecordingStore.loadManifest`,
//                                            including a low-rate trend signal
//                                            so the trend strip is exercised.
//    • makeWFDBRecord(into:)               → URL of the .hea file for a
//                                            single-frequency 8-lead ECG record
//                                            (single interleaved .dat). Used
//                                            by importer unit tests.
//    • makeMultiFrequencyRecord(into:)     → URL of the .hea file for a
//                                            mixed-rate record: 8 ECG signals
//                                            at 250 Hz + 2 trend signals
//                                            (fake HR, fake SpO₂) at 1 Hz,
//                                            each signal in its own .dat.
//

import Foundation

enum SyntheticRecording {

    // MARK: - Public API

    /// Returns a fully-imported Recording bundle directory. Uses the
    /// multi-frequency fixture so the welcome screen demo and UI tests both
    /// exercise the trend-strip path alongside the ECG canvas.
    static func makeFixture() throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotting-ui-test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let heaURL = try makeMultiFrequencyRecord(into: workDir)
        let outputDir = workDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)
        return summary.directory
    }

    /// Writes `synth.hea` + `synth.dat` (format 16, 8 ECG leads, 250 Hz, 10 s)
    /// into `directory` and returns the URL of the .hea file.
    static func makeWFDBRecord(into directory: URL) throws -> URL {
        let recordName = "synth"
        let labels: [String] = ["I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2"]
        let sampleRate = 250.0
        let durationSeconds = 10.0
        let sampleCount = Int(durationSeconds * sampleRate)     // 2500
        let gain: Double = 200.0                                // 200 LSB/mV
        let baseline = 0
        let datFilename = "\(recordName).dat"

        // Build .hea text
        var heaLines: [String] = ["\(recordName) \(labels.count) \(Int(sampleRate)) \(sampleCount)"]
        for label in labels {
            heaLines.append("\(datFilename) 16 \(Int(gain))(mV)/\(baseline) 16 0 0 0 0 \(label)")
        }
        let heaText = heaLines.joined(separator: "\n") + "\n"
        let heaURL = directory.appendingPathComponent("\(recordName).hea")
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)

        // Build .dat binary (interleaved Int16 LE)
        let signalCount = labels.count
        var int16Data = Data(count: signalCount * sampleCount * 2)
        int16Data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let int16Base = base.assumingMemoryBound(to: Int16.self)
            for sampleIdx in 0..<sampleCount {
                for signalIdx in 0..<signalCount {
                    let physical = fakeECGSample(index: sampleIdx, signalIndex: signalIdx, sampleRate: sampleRate)
                    let adcValue = Int16(
                        clamping: Int(physical * gain) + baseline
                    )
                    let frameOffset = sampleIdx * signalCount + signalIdx
                    int16Base[frameOffset] = adcValue.littleEndian
                }
            }
        }
        let datURL = directory.appendingPathComponent(datFilename)
        try int16Data.write(to: datURL, options: .atomic)

        return heaURL
    }

    /// Writes a multi-frequency record (8 ECG signals at 250 Hz + 2 trend
    /// signals — fake HR and SpO₂ — at 1 Hz) using one `.dat` per signal.
    /// Returns the URL of the `.hea` file.
    ///
    /// Base frame rate is 1 Hz so the slow trend signals can have `spf = 1`
    /// while ECG signals get `spf = 250` for their 250-Hz effective rate.
    static func makeMultiFrequencyRecord(into directory: URL) throws -> URL {
        let recordName = "synth"
        let ecgLabels: [String] = ["I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2"]
        let ecgRate = 250.0
        let baseFrameRate = 1.0
        let durationSeconds = 10.0
        let frameCount = Int(durationSeconds * baseFrameRate)              // 10
        let ecgSamplesPerSignal = Int(durationSeconds * ecgRate)           // 2500
        let ecgGain: Double = 200.0
        let baseline = 0

        var heaLines: [String] = [
            "\(recordName) \(ecgLabels.count + 2) \(Int(baseFrameRate)) \(frameCount)"
        ]

        // Write each ECG signal to its own per-signal .dat file (format 16, 250 spf).
        for (signalIdx, label) in ecgLabels.enumerated() {
            let datFilename = "\(recordName)_\(safeFileName(label)).dat"
            heaLines.append(
                "\(datFilename) 16x\(Int(ecgRate)) \(Int(ecgGain))(mV)/\(baseline) 16 0 0 0 0 \(label)"
            )

            var int16Data = Data(count: ecgSamplesPerSignal * 2)
            int16Data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                let int16Base = base.assumingMemoryBound(to: Int16.self)
                for sampleIdx in 0..<ecgSamplesPerSignal {
                    let physical = fakeECGSample(
                        index: sampleIdx,
                        signalIndex: signalIdx,
                        sampleRate: ecgRate
                    )
                    int16Base[sampleIdx] = Int16(
                        clamping: Int(physical * ecgGain) + baseline
                    ).littleEndian
                }
            }
            let datURL = directory.appendingPathComponent(datFilename)
            try int16Data.write(to: datURL, options: .atomic)
        }

        // Two low-rate trend signals: fake HR bpm and fake SpO₂ percent.
        // Stored as raw Int16 (gain = 1) — the value in the .dat IS the
        // physical value, no scaling.
        let trendSignals: [(label: String, unit: String, values: (Int) -> Int)] = [
            ("HR_bpm",   "bpm", { frame in 72 + Int(round(8 * sin(Double(frame) * .pi / 5))) }),   // 64…80
            ("SpO2_pct", "%",   { frame in max(90, 98 - frame / 2) })                                // 98 → 93
        ]

        for trend in trendSignals {
            let datFilename = "\(recordName)_\(safeFileName(trend.label)).dat"
            heaLines.append(
                "\(datFilename) 16x1 1(\(trend.unit))/\(baseline) 16 0 0 0 0 \(trend.label)"
            )

            var int16Data = Data(count: frameCount * 2)
            int16Data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                let int16Base = base.assumingMemoryBound(to: Int16.self)
                for frameIdx in 0..<frameCount {
                    int16Base[frameIdx] = Int16(clamping: trend.values(frameIdx)).littleEndian
                }
            }
            let datURL = directory.appendingPathComponent(datFilename)
            try int16Data.write(to: datURL, options: .atomic)
        }

        let heaText = heaLines.joined(separator: "\n") + "\n"
        let heaURL = directory.appendingPathComponent("\(recordName).hea")
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)
        return heaURL
    }

    // MARK: - Helpers

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("_") }
            .reduce("") { "\($0)\($1)" }
    }

    // MARK: - Signal synthesis

    /// Fake ECG-shaped waveform. Each lead gets a slightly different amplitude.
    private static func fakeECGSample(index: Int, signalIndex: Int, sampleRate: Double) -> Double {
        let t = Double(index) / sampleRate
        let bpm = 72.0
        let beatPhase = (t * bpm / 60.0).truncatingRemainder(dividingBy: 1.0)
        let amplitude = 0.8 + Double(signalIndex % 4) * 0.1     // 0.8 … 1.1 mV

        if beatPhase < 0.05 {
            return sin(beatPhase * .pi / 0.05) * amplitude       // QRS-ish spike
        }
        return sin(t * 2 * .pi * 1.2) * 0.05                     // baseline wander
    }
}
