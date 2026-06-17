//
//  ContentView.swift
//  Plotting

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var state: AppState = .empty
    @State private var importStates: [String: RecordImportState] = [:]
    @State private var selection: String?
    @State private var isImporterPresented = false
    @State private var errorMessage: String?
    @State private var currentImportTask: Task<Void, Never>?

    enum AppState {
        case empty
        case browsing(folder: URL, records: [WFDBRecordEntry])
        case directView(directory: URL, recording: Recording)
    }

    enum RecordImportState {
        case importing(progress: ImportProgress?)
        case imported(directory: URL, recording: Recording)
        case failed(message: String)
    }

    var body: some View {
        Group {
            switch state {
            case .empty:
                emptyShell
            case .browsing(let folder, let records):
                browseShell(folder: folder, records: records)
            case .directView(let directory, let recording):
                directShell(directory: directory, recording: recording)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderPick(result)
        }
        .alert(
            "Couldn't open record folder",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            #if DEBUG
            loadUITestSampleIfRequested()
            #endif
        }
    }

    // MARK: - Shells

    private var emptyShell: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Pick a folder containing WFDB records (.hea + .dat)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("empty-state-prompt")
                Button("Open Record Folder") { isImporterPresented = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("empty-state-open-button")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Plotting")
            .toolbar { openFolderToolbarItem }
        }
    }

    private func browseShell(folder: URL, records: [WFDBRecordEntry]) -> some View {
        NavigationSplitView {
            RecordSidebar(records: records, importStates: importStates, selection: $selection)
                .navigationTitle(folder.lastPathComponent)
                .navigationSplitViewColumnWidth(min: 160, ideal: 240, max: 320)
        } detail: {
            detailPane
                .navigationTitle(detailTitle)
                .toolbar { openFolderToolbarItem }
        }
        .onChange(of: selection) { _, newValue in
            handleSelectionChanged(newValue, folder: folder)
        }
    }

    private func directShell(directory: URL, recording: Recording) -> some View {
        NavigationStack {
            BedsideView(recording: recording, recordingDirectory: directory)
                .navigationTitle(recording.device)
                .toolbar { openFolderToolbarItem }
        }
    }

    private var openFolderToolbarItem: some ToolbarContent {
        ToolbarItem {
            Button {
                isImporterPresented = true
            } label: {
                Label("Open Record Folder", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("toolbar-open-button")
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let key = selection {
            switch importStates[key] {
            case .importing(let progress):
                importingPane(progress: progress)
            case .imported(let directory, let recording):
                BedsideView(recording: recording, recordingDirectory: directory)
                    .id(recording.id)
            case .failed(let message):
                failedPane(message: message, filename: key)
            case .none:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Select a record",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a record from the sidebar to view its signals.")
            )
        }
    }

    private func importingPane(progress: ImportProgress?) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress?.fractionComplete ?? 0)
                .frame(maxWidth: 240)
            Text(progress.map { "Importing… \(Int(($0.fractionComplete * 100).rounded()))%" } ?? "Importing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedPane(message: String, filename: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button("Retry") {
                if case .browsing(let folder, _) = state {
                    startImport(filename: filename, folder: folder)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailTitle: String {
        guard let key = selection else { return "Plotting" }
        if case .imported(_, let recording) = importStates[key] {
            return recording.device
        }
        return key
    }

    // MARK: - Folder + selection handling

    private func handleFolderPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let folderURL):
            do {
                let records = try scanFolder(folderURL)
                guard !records.isEmpty else {
                    errorMessage = "No WFDB records (.hea files) found in \(folderURL.lastPathComponent)."
                    return
                }
                currentImportTask?.cancel()
                importStates = [:]
                state = .browsing(folder: folderURL, records: records)
                let firstFilename = records.first?.filename
                selection = firstFilename
                if let firstFilename {
                    startImport(filename: firstFilename, folder: folderURL)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func scanFolder(_ folderURL: URL) throws -> [WFDBRecordEntry] {
        let needsScope = folderURL.startAccessingSecurityScopedResource()
        defer { if needsScope { folderURL.stopAccessingSecurityScopedResource() } }
        let files = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let heaURLs = files
            .filter { $0.pathExtension.lowercased() == "hea" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return heaURLs.compactMap { url -> WFDBRecordEntry? in
            guard let header = try? WFDBHeaderParser.parse(url: url) else { return nil }
            return WFDBRecordEntry(filename: url.lastPathComponent, header: header)
        }
    }

    /// Called when the sidebar selection changes.
    private func handleSelectionChanged(_ filename: String?, folder: URL) {
        guard let filename else { return }
        switch importStates[filename] {
        case .imported, .importing:
            return     // already cached or in flight
        default:
            startImport(filename: filename, folder: folder)
        }
    }

    private func startImport(filename: String, folder: URL) {
        importStates[filename] = .importing(progress: nil)
        currentImportTask?.cancel()
        currentImportTask = Task {
            do {
                let summary = try await RecordingStore.shared.importWFDB(
                    folderURL: folder,
                    heaFilename: filename,
                    progress: { snapshot in
                        Task { @MainActor in
                            if case .importing = importStates[filename] {
                                importStates[filename] = .importing(progress: snapshot)
                            }
                        }
                    }
                )
                await MainActor.run {
                    importStates[filename] = .imported(directory: summary.directory, recording: summary.recording)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        importStates[filename] = .failed(message: error.localizedDescription)
                    }
                }
            }
        }
    }

    #if DEBUG
    private func loadUITestSampleIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-sample") else { return }
        do {
            let directory = try SyntheticRecording.makeFixture()
            let recording = try RecordingStore.shared.loadManifest(at: directory)
            state = .directView(directory: directory, recording: recording)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif
}

// MARK: - Sidebar

private struct RecordSidebar: View {
    let records: [WFDBRecordEntry]
    let importStates: [String: ContentView.RecordImportState]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(records) { record in
                RecordRow(
                    record: record,
                    importState: importStates[record.filename]
                )
                .tag(record.filename)
                .accessibilityIdentifier("record-row-\(record.filename)")
            }
        }
    }
}

private struct RecordRow: View {
    let record: WFDBRecordEntry
    let importState: ContentView.RecordImportState?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.header.recordName)
                    .font(.body.monospaced())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let sigs = record.header.signalCount
        let hz   = Int(record.header.samplingFrequency)
        if record.durationSeconds > 0 {
            return "\(sigs) sig • \(hz) Hz • \(formatDuration(record.durationSeconds))"
        }
        return "\(sigs) sig • \(hz) Hz"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch importState {
        case .importing:
            ProgressView().controlSize(.small)
        case .imported:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .none:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}

// MARK: - Data model

/// One WFDB record found in a picked folder.
struct WFDBRecordEntry: Identifiable, Equatable {
    var id: String { filename }
    let filename: String     // e.g. "100.hea"
    let header: WFDBHeader

    var durationSeconds: Double {
        guard header.samplingFrequency > 0 else { return 0 }
        return Double(header.sampleCount) / header.samplingFrequency
    }
}
