import SwiftUI
import UniformTypeIdentifiers

struct LyraBackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .lyraClientBackup] }
    static var writableContentTypes: [UTType] { [.lyraClientBackup, .json] }

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
    @State private var exportDocument: LyraBackupFileDocument?
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
            Text("Exports scrobbles, listening exclusions, and playback preferences. Does not include downloaded audio or server credentials.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .lyraClientBackup,
            defaultFilename: defaultExportFilename,
        ) { _ in }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .lyraClientBackup],
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
            Text("Choose whether imported scrobbles and exclusions merge with or replace local data.")
        }
    }

    private var defaultExportFilename: String {
        let payload = LyraClientBackupService.makePayload(from: app)
        return LyraClientBackupService.suggestedFilename(for: payload)
    }

    private func exportBackup() {
        let payload = LyraClientBackupService.makePayload(from: app)
        guard let data = try? LyraClientBackupService.encode(payload) else {
            app.showTransientToast("Couldn't create backup")
            return
        }
        exportDocument = LyraBackupFileDocument(data: data)
        showingExporter = true
    }

    private func restore(mode: LyraClientBackupRestoreMode) {
        guard let data = pendingImportData else { return }
        do {
            let payload = try LyraClientBackupService.decode(data)
            let result = LyraClientBackupService.restore(payload: payload, into: app, mode: mode)
            restoreSummary = "Restored \(result.scrobbleCount) scrobbles, \(result.exclusionCount) exclusions."
            app.showTransientToast("Backup restored")
        } catch {
            app.showTransientToast("Invalid backup file")
        }
        pendingImportData = nil
    }
}
