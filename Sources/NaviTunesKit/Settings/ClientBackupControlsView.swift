import SwiftUI
import UniformTypeIdentifiers

struct NaviTunesBackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .navitunesClientBackup] }
    static var writableContentTypes: [UTType] { [.navitunesClientBackup, .json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ClientBackupControlsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var exportDocument: NaviTunesBackupFileDocument?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var pendingImportData: Data?
    @State private var showingRestoreModeDialog = false
    @State private var restoreSummary: String?

    var body: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("Export client backup", systemImage: "square.and.arrow.up")
            }

            Button {
                showingImporter = true
            } label: {
                Label("Import client backup", systemImage: "square.and.arrow.down")
            }

            if let restoreSummary {
                Text(restoreSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Exports scrobbles, playback preferences, Kill Mode history for this account, and your library pins. Does not include downloaded audio or server credentials.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .navitunesClientBackup,
            defaultFilename: defaultExportFilename,
        ) { _ in }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .navitunesClientBackup],
        ) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                pendingImportData = try? Data(contentsOf: url)
                showingRestoreModeDialog = true
            case .failure:
                app.showTransientToast("Couldn't read backup file")
            }
        }
        .confirmationDialog(
            "Restore backup",
            isPresented: $showingRestoreModeDialog,
            titleVisibility: .visible,
        ) {
            Button("Merge with existing data") {
                restore(mode: .merge)
            }
            Button("Replace existing data", role: .destructive) {
                restore(mode: .replace)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether imported scrobbles, Kill Mode history and pins merge with or replace what's on this iPhone.")
        }
    }

    private var defaultExportFilename: String {
        let payload = NaviTunesClientBackupService.makePayload(from: app)
        return NaviTunesClientBackupService.suggestedFilename(for: payload)
    }

    private func exportBackup() {
        let payload = NaviTunesClientBackupService.makePayload(from: app)
        guard let data = try? NaviTunesClientBackupService.encode(payload) else {
            app.showTransientToast("Couldn't create backup")
            return
        }
        exportDocument = NaviTunesBackupFileDocument(data: data)
        showingExporter = true
    }

    static func summary(for result: NaviTunesClientBackupRestoreResult) -> String {
        var parts = ["\(result.scrobbleCount) scrobble\(result.scrobbleCount == 1 ? "" : "s")"]
        if let count = result.killModePlaylistCount {
            parts.append("Kill Mode for \(count) playlist\(count == 1 ? "" : "s")")
        }
        if let count = result.pinCount {
            parts.append("\(count) pin\(count == 1 ? "" : "s")")
        }
        return "Restored " + parts.formatted(.list(type: .and)) + "."
    }

    private func restore(mode: NaviTunesClientBackupRestoreMode) {
        guard let data = pendingImportData else { return }
        do {
            let payload = try NaviTunesClientBackupService.decode(data)
            let result = NaviTunesClientBackupService.restore(payload: payload, into: app, mode: mode)
            restoreSummary = Self.summary(for: result)
            app.showTransientToast("Backup restored")
        } catch {
            app.showTransientToast("Invalid backup file")
        }
        pendingImportData = nil
    }
}
