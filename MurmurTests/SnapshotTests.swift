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
//  ▸ Currently opt-in only.
//  The test target runs inside a sandboxed host app (Murmur.app has
//  ENABLE_APP_SANDBOX=YES), which blocks read/write access to the
//  `__Snapshots__/` directory next to this file. Until that's settled
//  (likely a Debug-only sandbox disable on the Murmur target, or a host-app
//  refactor), every test in this suite is skipped by default.
//
//  To run locally: set env var `RUN_SNAPSHOT_TESTS=1` in the MurmurTests
//  scheme. Combine with `SNAPSHOT_TESTING_RECORD=all` (or pass
//  `record: .all` to `assertSnapshot`) for the first run to capture
//  baselines under `__Snapshots__/SnapshotTests/`. Commit the baselines,
//  unset record mode, then later runs assert against them.
//
//  Pin the suite to "Latest Release" only in Xcode Cloud — SwiftUI metrics
//  drift across macOS versions, so matrix runs would be flaky.
//
//  Tracked in ROADMAP.md "Quality Infrastructure / Phase 3".
//

#if canImport(SnapshotTesting)

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Murmur

@MainActor
final class SnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SNAPSHOT_TESTS"] == "1",
            "Snapshot tests are opt-in. Set RUN_SNAPSHOT_TESTS=1 on the MurmurTests scheme — see file header."
        )
    }

    /// Wraps a SwiftUI View in a sized NSHostingView. swift-snapshot-testing
    /// only ships an `.image` strategy for NSView on macOS — there's no
    /// direct SwiftUI-View snapshotter like the iOS UIKit path.
    private func host<V: View>(_ view: V, size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

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
        let size = CGSize(width: 280, height: 160)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: host(view, size: size), as: .image)
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
        let size = CGSize(width: 280, height: 110)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: host(view, size: size), as: .image)
    }

    // MARK: - WaveformTimeAxis

    func testTimeAxis_defaultTenSecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 0, endTime: 10)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: host(view, size: size), as: .image)
    }

    func testTimeAxis_zoomedSixtySecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 120, endTime: 180)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: host(view, size: size), as: .image)
    }

    // MARK: - WaveformVoltageAxis

    func testVoltageAxis_defaultRange() {
        let size = CGSize(width: 56, height: 188)
        let view = WaveformVoltageAxis(yMin: -1.5, yMax: 1.5, durationSeconds: 10)
            .frame(width: 56, height: 180)
            .padding(.vertical, 4)
            .background(Color.white)
        assertSnapshot(of: host(view, size: size), as: .image)
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
        assertSnapshot(of: host(view, size: CGSize(width: 552, height: 160)), as: .image)
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
        assertSnapshot(of: host(view, size: CGSize(width: 720, height: 60)), as: .image)
    }

    func testFindingsSummaryHeader_emptyState() {
        let summary = AnnotationSummary.empty
        let view = FindingsSummaryHeader(
            summary: summary,
            filter: .constant(FindingFilter())
        )
        .frame(width: 360)
        .background(Color.white)
        assertSnapshot(of: host(view, size: CGSize(width: 360, height: 60)), as: .image)
    }
}

#endif // canImport(SnapshotTesting)
