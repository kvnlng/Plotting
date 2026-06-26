//
//  SnapshotTests.swift
//  MurmurTests
//
//  Reference-image regression suite for the SwiftUI overlays that surround
//  the Metal waveform canvas. The canvas itself is intentionally skipped —
//  GPU pixel diffs across MSAA settings and OS versions are unreliable. The
//  overlays underneath (axes, tooltip, density timeline, summary header) are
//  where layout regressions actually bite the analyst.
//
//  ▸ Currently dormant.
//  Wrapped in `#if canImport(SnapshotTesting)` so it compiles to nothing
//  until the SPM dependency lands. Today, pointfreeco/swift-snapshot-testing
//  pins `swift-syntax` to <605, while the in-project SwiftLint plugin
//  requires a 604/605 prerelease — the two won't co-resolve. Revisit once
//  snapshot-testing tags a release that bumps the swift-syntax ceiling, or
//  once we move SwiftLint to a Homebrew + Run-Script integration. Tracked
//  in ROADMAP.md "Quality Infrastructure / Phase 3".
//
//  Setup notes for when the dep is unblocked:
//  - Attach `swift-snapshot-testing` to the MurmurTests target only.
//  - Baselines live in __Snapshots__/SnapshotTests/ next to this file.
//  - To re-record after intentional UI changes: pass `record: .all` to one
//    of the `assertSnapshot` calls (or set the env var
//    `SNAPSHOT_TESTING_RECORD=all` in the test scheme), run once, then
//    revert and commit the new images.
//  - Pin CI matrix to a single macOS version. SwiftUI metrics drift across
//    OS releases — running these on both Tahoe and Sequoia will produce
//    spurious diffs.
//

#if canImport(SnapshotTesting)

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Murmur

@MainActor
final class SnapshotTests: XCTestCase {

    // MARK: - AnnotationTooltip

    func testAnnotationTooltip_pointWithConfidenceAndNote() {
        let annotation = Annotation(
            kind: .point,
            sampleIndex: 1500,
            category: "PVC",
            confidence: 0.92,
            severity: .warning,
            source: "demo-detector-v2",
            note: "Couplet, R-on-T morphology"
        )
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    func testAnnotationTooltip_rangeWithoutNote() {
        let annotation = Annotation(
            kind: .range,
            sampleIndex: 6000,
            endSampleIndex: 9500,
            category: "VT",
            severity: .critical,
            source: "vt-detector-v1"
        )
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    // MARK: - WaveformTimeAxis

    func testTimeAxis_defaultTenSecondViewport() {
        let view = WaveformTimeAxis(startTime: 0, endTime: 10)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    func testTimeAxis_zoomedSixtySecondViewport() {
        let view = WaveformTimeAxis(startTime: 120, endTime: 180)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    // MARK: - WaveformVoltageAxis

    func testVoltageAxis_defaultRange() {
        let view = WaveformVoltageAxis(yMin: -1.5, yMax: 1.5, durationSeconds: 10)
            .frame(width: 56, height: 180)
            .padding(.vertical, 4)
            .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    // MARK: - FindingDensityTimeline

    func testFindingDensityTimeline_mixedCategories() {
        let totalSamples: Int64 = 30_000
        let annotations: [Annotation] = [
            Annotation(kind: .point, sampleIndex: 1_000,  category: "PVC",  severity: .warning,  source: "demo"),
            Annotation(kind: .point, sampleIndex: 2_500,  category: "PVC",  severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 5_500,  category: "PVC",  severity: .info,     source: "demo"),
            Annotation(kind: .range, sampleIndex: 10_000, endSampleIndex: 17_500,
                       category: "AFib", severity: .warning,  source: "demo"),
            Annotation(kind: .range, sampleIndex: 20_000, endSampleIndex: 21_200,
                       category: "VT",   severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 25_000, category: "noise", severity: .info, source: "demo")
        ]
        let viewport = RecordingViewport(
            totalSamples: totalSamples,
            sampleRate: 250,
            initialDurationSeconds: 10
        )
        let view = FindingDensityTimeline(
            annotations: annotations,
            totalSamples: totalSamples,
            sampleRate: 250,
            viewport: viewport,
            onJump: { _ in }
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    // MARK: - FindingsSummaryHeader

    func testFindingsSummaryHeader_mixedFindings() {
        let annotations: [Annotation] = [
            Annotation(kind: .point, sampleIndex: 100,   category: "PVC",  severity: .warning,  source: "demo"),
            Annotation(kind: .point, sampleIndex: 200,   category: "PVC",  severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 350,   category: "PVC",  severity: .info,     source: "demo"),
            Annotation(kind: .range, sampleIndex: 1_000, endSampleIndex: 1_750,
                       category: "AFib", severity: .warning,  source: "demo"),
            Annotation(kind: .range, sampleIndex: 2_000, endSampleIndex: 2_120,
                       category: "VT",   severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 2_500, category: "noise", severity: .info, source: "demo")
        ]
        let summary = AnnotationSummary.build(
            from: annotations,
            recordingDurationSamples: 3_000,
            sampleRate: 250
        )
        let view = FindingsSummaryHeader(
            summary: summary,
            filter: .constant(FindingFilter())
        )
        .frame(width: 720)
        .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }

    func testFindingsSummaryHeader_emptyState() {
        let summary = AnnotationSummary.empty
        let view = FindingsSummaryHeader(
            summary: summary,
            filter: .constant(FindingFilter())
        )
        .frame(width: 360)
        .background(Color.white)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }
}

#endif // canImport(SnapshotTesting)
