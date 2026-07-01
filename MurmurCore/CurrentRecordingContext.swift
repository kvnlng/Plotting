//
//  CurrentRecordingContext.swift
//  MurmurCore
//
//  Process-wide "which recording is currently loaded?" state. The
//  main window's ContentView drives it as the analyst opens / closes
//  recordings; auxiliary windows (the ECG Metrics window, future
//  citation-report window, etc.) read from it via
//  `CurrentRecordingContext.shared` and re-render when the recording
//  changes.
//
//  Public so the App target (which is where the app's paid-feature
//  orchestration lives) can observe recording changes without
//  ContentView having to know about downstream consumers — inverting
//  the dependency in the direction that keeps MurmurCore ignorant of
//  the paid frameworks.
//

import Foundation
import Observation

/// Live "current recording" state. `@MainActor` because every UI
/// surface that reads it runs on main, and every ContentView state
/// transition that writes to it is already main-actor isolated.
@MainActor
@Observable
public final class CurrentRecordingContext {

    /// Shared instance the app uses at runtime. Tests should construct
    /// a fresh `CurrentRecordingContext()` to keep parallel runs
    /// isolated from each other and from the app's live state.
    public static let shared = CurrentRecordingContext()

    /// The recording the analyst is currently looking at, or `nil`
    /// when the viewer is showing the welcome screen / browsing a
    /// folder. Auxiliary windows should treat `nil` as their empty
    /// state.
    public private(set) var recording: Recording?

    /// Directory containing the currently-loaded recording's bundle,
    /// for callers that need to read sidecar files (annotations.json,
    /// disposition-store JSON, etc.) alongside the manifest.
    public private(set) var directory: URL?

    public init() {}

    /// Publish that `recording` is now current, loaded from `directory`.
    public func set(recording: Recording, directory: URL) {
        self.recording = recording
        self.directory = directory
    }

    /// Publish that no recording is currently loaded (welcome screen,
    /// folder-browsing view, etc.).
    public func clear() {
        recording = nil
        directory = nil
    }
}
