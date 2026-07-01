//
//  RandomizedTests.swift
//  MurmurCoreTests
//
//  Property / invariant tests for load-bearing continuous-input
//  functions in MurmurCore. Uniform sampling; every sample must
//  pass (no "N of M tolerable" — see the randomized-test-strategy
//  feedback memory). Seed is a constant on local runs (devs get
//  identical sequences across their runs) and derived from the
//  commit SHA on Xcode Cloud (via the `CI_COMMIT` env var) so each
//  commit explores a slightly different corner of the space.
//
//  Failures include the seed and the specific failing input in
//  their assertion message so any red row is directly reproducible.
//

import Foundation
import Testing
@testable import MurmurCore

// MARK: - Sampling infrastructure

/// xorshift64 — deterministic given the same seed; plenty of entropy
/// for randomized invariant testing (this is not cryptography).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        // Splitmix-style stir so a zero seed doesn't degenerate the
        // shift chain into all zeros.
        let stirred = (seed &* 0x9E3779B97F4A7C15) ^ 0x1234567890ABCDEF
        self.state = stirred == 0 ? 0xDEADBEEF : stirred
    }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private enum RandomSampler {
    /// The seed used for every parameterized argument set below.
    /// Constant locally (project-level literal), commit-derived on
    /// Xcode Cloud so successive builds probe different inputs.
    static let seed: UInt64 = {
        if let sha = ProcessInfo.processInfo.environment["CI_COMMIT"] {
            let prefix = String(sha.prefix(16))
            if let parsed = UInt64(prefix, radix: 16), parsed != 0 { return parsed }
        }
        return 0x4D75726D75725F52  // "MurmuR" — arbitrary literal
    }()

    /// Generic N-count map with a single shared RNG so all callers
    /// draw from the same deterministic stream.
    static func map<T>(count: Int, _ generator: (inout SeededRNG) -> T) -> [T] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in generator(&rng) }
    }

    /// Realistic tap-fraction inputs: widths across the range a
    /// bedside-view lane might actually get, and x values that
    /// include the below-0 and above-width regions so the clamps
    /// are exercised in both directions (~40% of samples are
    /// out-of-range so the clamp branches see substantial coverage).
    static func tapFractionInputs(count: Int) -> [TapFractionInput] {
        map(count: count) { rng in
            let width = Double.random(in: 50.0..<2000.0, using: &rng)
            let bucket = Int.random(in: 0..<5, using: &rng)
            let x: Double
            switch bucket {
            case 0: x = Double.random(in: -100.0..<0.0, using: &rng)
            case 1: x = Double.random(in: width..<(width + 100.0), using: &rng)
            default: x = Double.random(in: 0.0..<width, using: &rng)
            }
            return TapFractionInput(x: x, width: width)
        }
    }

    /// Realistic animateJump inputs: recordings from ~20 s to ~13 min
    /// at 250 Hz, viewport widths from 0.8 s to 20 s, fractions
    /// uniform in [0, 1). Every triple is generated so
    /// widthSamples < totalSamples, which is what the viewport
    /// initializer expects anyway.
    static func animateJumpInputs(count: Int) -> [AnimateJumpInput] {
        map(count: count) { rng in
            let total = Int64.random(in: 5000..<200_000, using: &rng)
            let widthCap = min(total / 2, 5000)
            let width = Int64.random(in: 200..<max(201, widthCap), using: &rng)
            let fraction = Double.random(in: 0.0..<1.0, using: &rng)
            return AnimateJumpInput(
                totalSamples: total,
                widthSamples: width,
                fraction: fraction
            )
        }
    }
}

// MARK: - Inputs

struct TapFractionInput: CustomStringConvertible, Sendable {
    let x: Double
    let width: Double
    var description: String {
        "x=\(String(format: "%.2f", x)) width=\(String(format: "%.2f", width))"
    }
}

struct AnimateJumpInput: CustomStringConvertible, Sendable {
    let totalSamples: Int64
    let widthSamples: Int64
    let fraction: Double
    var description: String {
        "total=\(totalSamples) width=\(widthSamples) f=\(String(format: "%.4f", fraction))"
    }
}

// MARK: - Tap-fraction invariants

@Suite("RecordingViewport.tapFraction — property tests")
@MainActor
struct TapFractionInvariantTests {

    @Test("Output is always in [0, 1] across a wide input distribution",
          arguments: RandomSampler.tapFractionInputs(count: 200))
    func staysInRange(input: TapFractionInput) {
        let f = RecordingViewport.tapFraction(x: input.x, width: input.width)
        #expect(f >= 0.0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) → \(f) (below 0)")
        #expect(f <= 1.0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) → \(f) (above 1)")
    }

    @Test("x <= 0 clamps to exactly 0",
          arguments: RandomSampler.tapFractionInputs(count: 200).filter { $0.x <= 0 })
    func clampsBelow(input: TapFractionInput) {
        let f = RecordingViewport.tapFraction(x: input.x, width: input.width)
        #expect(f == 0.0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) → \(f) (expected exact 0)")
    }

    @Test("x >= width clamps to exactly 1",
          arguments: RandomSampler.tapFractionInputs(count: 200).filter { $0.x >= $0.width })
    func clampsAbove(input: TapFractionInput) {
        let f = RecordingViewport.tapFraction(x: input.x, width: input.width)
        #expect(f == 1.0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) → \(f) (expected exact 1)")
    }

    /// Degenerate widths (zero, negative, sub-1) must not crash and
    /// must still produce a fraction in `[0, 1]`. Explicit
    /// non-random cases — the space of "widths ≤ 0" is small and
    /// deserves example-based coverage.
    @Test("Degenerate widths yield a fraction in [0, 1] and never crash",
          arguments: [
            (x: 100.0, w: 0.0),
            (x: -50.0, w: -10.0),
            (x: 500.0, w: 0.5),
            (x: 0.0, w: 0.0),
          ])
    func degenerateWidths(x: Double, w: Double) {
        let f = RecordingViewport.tapFraction(x: x, width: w)
        #expect(f >= 0.0 && f <= 1.0,
                "degenerate width=\(w) x=\(x) → \(f)")
    }
}

// MARK: - animateJump invariants

@Suite("RecordingViewport.animateJump — property tests")
@MainActor
struct AnimateJumpInvariantTests {

    private static let sampleRate = 250.0

    /// Duration=0 skips the animation branch and takes the
    /// synchronous set-start path — inspecting `startSample`
    /// immediately after the call is safe.
    @Test("From startSample=0, jump lands on the expected clamped position",
          arguments: RandomSampler.animateJumpInputs(count: 200))
    func directTargetMath(input: AnimateJumpInput) async {
        let initialSeconds = Double(input.widthSamples) / Self.sampleRate
        let viewport = RecordingViewport(
            totalSamples: input.totalSamples,
            sampleRate: Self.sampleRate,
            initialDurationSeconds: initialSeconds
        )
        // We depend on the fresh viewport starting at 0.
        #expect(viewport.startSample == 0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) initial startSample != 0")

        let width = viewport.endSample - viewport.startSample
        let target = Int64(Double(input.totalSamples) * input.fraction)
        let maxStart = max(0, input.totalSamples - width)
        let expected = min(maxStart, max(0, target - width / 2))

        viewport.animateJump(toFraction: input.fraction, duration: 0)

        #expect(viewport.startSample == expected,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) width=\(width) target=\(target) → startSample=\(viewport.startSample), expected=\(expected)")
    }

    @Test("End state stays within [0, totalSamples - width]",
          arguments: RandomSampler.animateJumpInputs(count: 200))
    func endStateInBounds(input: AnimateJumpInput) async {
        let initialSeconds = Double(input.widthSamples) / Self.sampleRate
        let viewport = RecordingViewport(
            totalSamples: input.totalSamples,
            sampleRate: Self.sampleRate,
            initialDurationSeconds: initialSeconds
        )
        viewport.animateJump(toFraction: input.fraction, duration: 0)

        let width = viewport.endSample - viewport.startSample
        #expect(viewport.startSample >= 0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) startSample<0: \(viewport.startSample)")
        #expect(viewport.startSample + width <= input.totalSamples,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) end=\(viewport.endSample) > total=\(input.totalSamples)")
    }

    /// The load-bearing invariant this whole exercise came from:
    /// **if the click's target position is above the "no-op zone",
    /// the viewport must actually move off `start=0`.** Filter to
    /// only the inputs whose target lands above the no-op boundary
    /// (`target - width/2 > 0`); every one of them must produce a
    /// visible viewport change.
    @Test("Viewport moves off start=0 whenever target is above the no-op zone",
          arguments: RandomSampler.animateJumpInputs(count: 200).filter { input in
              let target = Int64(Double(input.totalSamples) * input.fraction)
              return (target - input.widthSamples / 2) > 0
          })
    func movesOffStart(input: AnimateJumpInput) async {
        let initialSeconds = Double(input.widthSamples) / Self.sampleRate
        let viewport = RecordingViewport(
            totalSamples: input.totalSamples,
            sampleRate: Self.sampleRate,
            initialDurationSeconds: initialSeconds
        )
        #expect(viewport.startSample == 0)
        viewport.animateJump(toFraction: input.fraction, duration: 0)
        #expect(viewport.startSample > 0,
                "seed=\(String(RandomSampler.seed, radix: 16)) input=\(input) — viewport stayed at start=0 despite target above the no-op zone")
    }
}
