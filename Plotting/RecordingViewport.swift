//
//  RecordingViewport.swift
//  Plotting
//
//  Shared time-window state for one recording's bedside view. Every channel
//  panel in a Recording renders the same range so leads scroll and zoom in
//  lock-step — matching the convention every clinical bedside monitor uses.
//
//  Pan/zoom gestures and overview-ribbon scrubs all funnel through this object,
//  and each ChannelPanel observes changes via the Observation framework.
//

import Foundation

@MainActor
@Observable
final class RecordingViewport {
    let totalSamples: Int64
    let sampleRate: Double
    /// Smallest allowed window — we never let users zoom below 100 ms.
    let minSamples: Int64

    private(set) var startSample: Int64
    private(set) var endSample: Int64

    init(totalSamples: Int64, sampleRate: Double, initialDurationSeconds: Double = 10) {
        let total = max(0, totalSamples)
        let rate = max(1, sampleRate)
        self.totalSamples = total
        self.sampleRate = rate
        self.minSamples = max(2, Int64(0.1 * rate))

        let initialWidth = min(total, max(2, Int64(initialDurationSeconds * rate)))
        self.startSample = 0
        self.endSample = max(2, initialWidth)
    }

    var rangeSamples: Range<Int64> { startSample..<endSample }

    var durationSeconds: Double { Double(endSample - startSample) / sampleRate }

    /// Pan by an arbitrary sample delta, clamped to recording bounds.
    func pan(bySamples delta: Int64) {
        setStart(startSample + delta)
    }

    /// Move the window so it starts at `newStart`, preserving width.
    func setStart(_ newStart: Int64) {
        let width = endSample - startSample
        let maxStart = max(0, totalSamples - width)
        let clamped = min(max(0, newStart), maxStart)
        startSample = clamped
        endSample = clamped + width
    }

    /// Change the window width, keeping `anchorFraction` of the current viewport
    /// (0 = left edge, 0.5 = center, 1 = right edge) anchored to the same sample.
    func setWidth(_ newWidth: Int64, anchorFraction: Double) {
        let clampedWidth = min(max(minSamples, newWidth), max(minSamples, totalSamples))
        let currentWidth = endSample - startSample
        guard clampedWidth != currentWidth else { return }

        let anchorSample = startSample + Int64(Double(currentWidth) * anchorFraction)
        let proposedStart = anchorSample - Int64(Double(clampedWidth) * anchorFraction)
        let maxStart = max(0, totalSamples - clampedWidth)
        let clampedStart = min(max(0, proposedStart), maxStart)
        startSample = clampedStart
        endSample = clampedStart + clampedWidth
    }

    /// Center the viewport around `fraction` (0...1) of the total recording,
    /// preserving the current width.
    func jump(toFraction fraction: Double) {
        let f = min(1.0, max(0.0, fraction))
        let target = Int64(Double(totalSamples) * f)
        let width = endSample - startSample
        setStart(target - width / 2)
    }
}
