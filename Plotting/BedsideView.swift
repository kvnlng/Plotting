//
//  BedsideView.swift
//  Plotting
//
//  Stacked channel panels driven by a shared `RecordingViewport`. The main
//  waveform is GPU-rendered (Metal) via `WaveformCanvas`; SwiftUI overlays
//  draw the axis labels and annotation symbols on top.
//
//  Drag on a chart pans all channels in lock-step; pinch zooms. Click/drag
//  on the overview ribbon scrubs.
//

import Charts
import SwiftUI

struct BedsideView: View {
    let recording: Recording
    let recordingDirectory: URL

    @State private var viewport: RecordingViewport
    @State private var filter = FindingFilter()
    @State private var showFindings = true

    static let initialDurationSeconds: Double = 10

    init(recording: Recording, recordingDirectory: URL) {
        self.recording = recording
        self.recordingDirectory = recordingDirectory
        let first = recording.channels.first
        _viewport = State(initialValue: RecordingViewport(
            totalSamples: first?.sampleCount ?? 0,
            sampleRate: first?.sampleRate ?? 250,
            initialDurationSeconds: Self.initialDurationSeconds
        ))
    }

    /// Annotations that survive the current filter. Drives both the canvas and
    /// the findings panel so they stay in sync.
    private var filteredAnnotations: [Annotation] {
        recording.annotations.filter(filter.matches)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryHeader
                ForEach(recording.channels) { channel in
                    ChannelPanel(
                        channel: channel,
                        directory: recordingDirectory,
                        viewport: viewport,
                        annotations: filteredAnnotations
                    )
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("bedside-view")
        .inspector(isPresented: $showFindings) {
            FindingsPanel(
                annotations: recording.annotations,
                viewport: viewport,
                sampleRate: recording.channels.first?.sampleRate ?? 250,
                filter: $filter
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showFindings.toggle()
                } label: {
                    Label("Findings", systemImage: "stethoscope.circle")
                }
                .help("Show or hide the findings panel")
                .accessibilityIdentifier("findings-toggle")
            }
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.device)
                .font(.title3.weight(.semibold))
            Text(summaryDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(navigationHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("bedside-summary")
    }

    private var summaryDetail: String {
        let channelCount = recording.channels.count
        let duration = Self.formatDuration(seconds: totalDurationSeconds)
        let start = recording.channels.first?.startDate
            .formatted(date: .numeric, time: .standard) ?? "—"
        var detail = "\(channelCount) channels  •  \(duration)  •  starts \(start)"
        if !recording.annotations.isEmpty {
            detail += "  •  \(recording.annotations.count) annotations"
        }
        return detail
    }

    private var navigationHint: String {
        "Drag to pan  •  Pinch to zoom  •  Click the ribbon to jump"
    }

    private var totalDurationSeconds: Double {
        recording.channels.first?.durationSeconds ?? 0
    }

    private static func formatDuration(seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}

// MARK: - ECG grid spec (used by both Metal renderer and SwiftUI axis overlays)

/// Picks the major/minor grid spacings (in seconds / mV) for a viewport of the
/// given duration. Adaptive density keeps the active gridline count bounded
/// across every zoom level so reading the chart never becomes a pink wash.
struct ECGGridSpec: Equatable {
    let xMinor: Double          // seconds
    let xMajor: Double
    let yMinor: Double          // mV (or matching unit)
    let yMajor: Double

    static func forDuration(seconds: Double) -> ECGGridSpec {
        switch seconds {
        case ..<30:
            return ECGGridSpec(xMinor: 0.04, xMajor: 0.2,  yMinor: 0.1, yMajor: 0.5)
        case ..<300:        // up to 5 min
            return ECGGridSpec(xMinor: 0.2,  xMajor: 1.0,  yMinor: 0.1, yMajor: 0.5)
        case ..<1800:       // up to 30 min
            return ECGGridSpec(xMinor: 1.0,  xMajor: 5.0,  yMinor: 0.5, yMajor: 1.0)
        case ..<7200:       // up to 2 hr
            return ECGGridSpec(xMinor: 5.0,  xMajor: 30.0, yMinor: 0.5, yMajor: 2.5)
        default:
            return ECGGridSpec(xMinor: 30.0, xMajor: 300.0, yMinor: 1.0, yMajor: 5.0)
        }
    }
}

// MARK: - Channel panel

private struct ChannelPanel: View {
    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport
    let annotations: [Annotation]

    @State private var canvasSize: CGSize = .zero
    @State private var clippedRanges: [ClippedRange] = []

    // Per-gesture starting state so each gesture is computed against the
    // viewport as it was when the gesture began, not the most recent update.
    @State private var dragStartRange: Range<Int64>?
    @State private var zoomStartWidth: Int64?

    private static let yMin: Double = -5
    private static let yMax: Double =  5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            HStack(alignment: .top, spacing: 0) {
                WaveformVoltageAxis(yMin: Self.yMin, yMax: Self.yMax, durationSeconds: durationSeconds)
                    .frame(minHeight: 160)
                canvasArea
            }
            WaveformTimeAxis(startTime: startTime, endTime: endTime)
                .padding(.leading, 56)
            OverviewRibbon(
                channel: channel,
                directory: directory,
                viewport: viewport
            )
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("channel-panel-\(channel.name)")
        .task { await scanForOffScale() }
    }

    private var canvasArea: some View {
        ZStack(alignment: .topLeading) {
            WaveformCanvas(
                channel: channel,
                directory: directory,
                startSample: viewport.startSample,
                endSample: viewport.endSample,
                annotations: visibleAnnotations
            )
            .frame(minHeight: 160)

            WaveformClippingOverlay(
                clippedRanges: clippedRanges,
                startSample: viewport.startSample,
                endSample: viewport.endSample
            )

            WaveformAnnotationOverlay(
                annotations: visibleAnnotations,
                startSample: viewport.startSample,
                endSample: viewport.endSample
            )
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: CanvasSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
        .contentShape(Rectangle())
        .gesture(panGesture())
        .gesture(zoomGesture())
    }

    /// Annotations that overlap the current viewport. Point findings are visible
    /// when their sample falls inside the range; range findings are visible when
    /// their [start, end] interval intersects it. The list is sorted by sample
    /// index, so we can scan from a small lookahead window.
    private var visibleAnnotations: [Annotation] {
        guard !annotations.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return annotations.filter { ann in
            switch ann.kind {
            case .point:
                return range.contains(ann.sampleIndex)
            case .range:
                let start = ann.sampleIndex
                let end   = ann.endSampleIndex ?? ann.sampleIndex
                return end >= range.lowerBound && start < range.upperBound
            }
        }
    }

    private var startTime: Double {
        Double(viewport.startSample) / channel.sampleRate
    }
    private var endTime: Double {
        Double(viewport.endSample) / channel.sampleRate
    }
    private var durationSeconds: Double { endTime - startTime }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(channel.name).font(.headline)
            Text(channel.unit.isEmpty ? "" : "(\(channel.unit))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !clippedRanges.isEmpty {
                Label("\(clippedRanges.count) off-scale", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("\(clippedRanges.count) segment\(clippedRanges.count == 1 ? "" : "s") exceed ±5 mV and aren't drawn")
            }
            Spacer()
            Text(timeWindowLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(Int(channel.sampleRate)) Hz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeWindowLabel: String {
        String(format: "%.2f – %.2f s", startTime, endTime)
    }

    /// One-time scan over the full channel at panel mount. The result feeds
    /// both the chevron overlay and the header off-scale badge.
    private func scanForOffScale() async {
        let url = directory.appendingPathComponent(channel.storageFileName)
        let total = channel.sampleCount
        guard total > 0 else { return }
        let result: [ClippedRange] = await Task.detached(priority: .utility) {
            guard let access = try? BinaryRecordingFile.mappedAccess(url: url) else {
                return []
            }
            let samples = access.samples(range: 0..<total)
            return ClippedRangeScanner.scan(
                samples: samples,
                clipMin: Float(Self.yMin),
                clipMax: Float(Self.yMax)
            )
        }.value
        await MainActor.run { clippedRanges = result }
    }

    // MARK: Gestures

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartRange == nil { dragStartRange = viewport.rangeSamples }
                guard let start = dragStartRange, canvasSize.width > 0 else { return }
                let width = start.upperBound - start.lowerBound
                let samplesPerPixel = Double(width) / Double(canvasSize.width)
                let deltaSamples = Int64(-value.translation.width * samplesPerPixel)
                viewport.setStart(start.lowerBound + deltaSamples)
            }
            .onEnded { _ in dragStartRange = nil }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStartWidth == nil {
                    zoomStartWidth = viewport.endSample - viewport.startSample
                }
                guard let startWidth = zoomStartWidth else { return }
                let factor = 1.0 / max(0.01, value.magnification)
                let newWidth = Int64(Double(startWidth) * factor)
                viewport.setWidth(newWidth, anchorFraction: 0.5)
            }
            .onEnded { _ in zoomStartWidth = nil }
    }
}

// MARK: - Overview ribbon

private struct OverviewRibbon: View {
    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport

    @State private var bins: [PyramidBin] = []
    @State private var loadError: String?

    /// Minimum on-screen width for the viewport indicator. At deep zoom (e.g.
    /// 10 s of a 30-min recording, ~0.5%), the proportional width is a few
    /// pixels — too thin to see. We floor at this so the user can always
    /// perceive where they are. Anything wider than this stays proportional.
    private static let minIndicatorPx: CGFloat = 18
    private static let ribbonHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    envelopeChart
                    viewportIndicator(width: geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: Self.ribbonHeight)
            scaleStrip
        }
        .padding(.top, 4)
        .accessibilityIdentifier("overview-ribbon-\(channel.name)")
        .task { await loadOverview() }
    }

    /// "0s ──── 5.2 min — 5.5 min ──── 30.0 min" style scale strip. Shows the
    /// recording's total extent at the edges and the current viewport in the
    /// middle so the analyst sees both "how much we're looking at" and "where
    /// we are" at a glance.
    private var scaleStrip: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(formatDuration(0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(currentWindowLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(formatDuration(totalDurationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 12)
    }

    private var totalDurationSeconds: Double {
        guard viewport.sampleRate > 0 else { return 0 }
        return Double(viewport.totalSamples) / viewport.sampleRate
    }

    private var currentWindowLabel: String {
        guard viewport.sampleRate > 0 else { return "—" }
        let startSec = Double(viewport.startSample) / viewport.sampleRate
        let endSec   = Double(viewport.endSample)   / viewport.sampleRate
        let widthSec = endSec - startSec
        return "\(formatDuration(startSec)) – \(formatDuration(endSec))  •  \(formatDuration(widthSec)) window"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return seconds < 10
                ? String(format: "%.1f s", seconds)
                : String(format: "%.0f s", seconds)
        }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }

    @ViewBuilder
    private var envelopeChart: some View {
        if let loadError {
            Text(loadError)
                .font(.caption2)
                .foregroundStyle(.red)
        } else if bins.isEmpty {
            Rectangle().fill(.quaternary)
        } else {
            Chart {
                ForEach(Array(bins.enumerated()), id: \.offset) { idx, bin in
                    if !bin.isNaN {
                        AreaMark(
                            x: .value("Bin", idx),
                            yStart: .value("Min", bin.min),
                            yEnd: .value("Max", bin.max)
                        )
                        .foregroundStyle(.secondary.opacity(0.55))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...Double(max(1, bins.count - 1)))
        }
    }

    private func viewportIndicator(width: CGFloat) -> some View {
        let totalSamples = Double(viewport.totalSamples)
        guard totalSamples > 0 else { return AnyView(EmptyView()) }
        let leftFrac  = Double(viewport.startSample) / totalSamples
        let widthFrac = Double(viewport.endSample - viewport.startSample) / totalSamples
        // Proportional width, but never thinner than minIndicatorPx so the
        // indicator stays perceivable at deep zoom. The indicator's center
        // still tracks the viewport center after the floor kicks in, so the
        // user can see where they are in the recording.
        let propWidth = CGFloat(widthFrac) * width
        let visibleWidth = max(Self.minIndicatorPx, propWidth)
        let centerFrac = leftFrac + widthFrac / 2
        let centerX = CGFloat(centerFrac) * width
        let leftX = max(0, min(width - visibleWidth, centerX - visibleWidth / 2))
        return AnyView(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1.25)
                )
                .frame(width: visibleWidth)
                .offset(x: leftX)
                .allowsHitTesting(false)
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = Double(value.location.x / width)
                viewport.jump(toFraction: fraction)
            }
    }

    private func loadOverview() async {
        guard let level = selectLevel() else { return }
        let url = directory.appendingPathComponent(level.storageFileName)
        do {
            let access = try PyramidLevelFile.mappedAccess(url: url)
            let allBins = access.bins(range: 0..<access.binCount)
            await MainActor.run { bins = allBins }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
        }
    }

    private func selectLevel() -> PyramidLevel? {
        guard !channel.pyramid.isEmpty else { return nil }
        let target: Int64 = 400
        return channel.pyramid.min(by: { abs($0.binCount - target) < abs($1.binCount - target) })
    }
}

// MARK: - Layout plumbing

private struct CanvasSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
