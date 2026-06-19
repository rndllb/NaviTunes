import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct RadioCoverCropSubject: Identifiable {
    let id = UUID()
    let imageData: Data
}

struct AddCustomRadioStationSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var streamURLText = ""
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var coverCropSubject: RadioCoverCropSubject?
    @State private var pendingCoverData: Data?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Station name", text: $name)
#if os(iOS)
                        .musicTextInputAutocapitalization(.words)
#endif
                    TextField("Stream URL", text: $streamURLText)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                } footer: {
                    Text("Paste an http or https stream URL (e.g. .mp3, .aac, HLS).")
                }

                Section {
                    coverPreview
                    PhotosPicker(selection: $coverPickerItem, matching: .images, photoLibrary: .shared()) {
                        Label(pendingCoverData == nil ? "Choose cover art" : "Change cover art", systemImage: "photo")
                    }
                    if pendingCoverData != nil {
                        Button("Remove cover art", role: .destructive) {
                            pendingCoverData = nil
                            coverPickerItem = nil
                        }
                    }
                } header: {
                    Text("Cover Art")
                } footer: {
                    Text("Optional square artwork for this station. Defaults to a generated mesh if omitted.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(MusicDesign.background)
            .navigationTitle("Add Station")
            .musicNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .musicNavigationChrome()
            .onChange(of: coverPickerItem) { _, item in
                guard let item else { return }
                Task { await handleCoverPickerSelection(item) }
            }
#if os(iOS)
            .fullScreenCover(item: $coverCropSubject) { subject in
                SquareImageCropView(
                    image: UIImage(data: subject.imageData) ?? UIImage(),
                    onCancel: { coverCropSubject = nil },
                    onCrop: { data in
                        pendingCoverData = data
                        coverCropSubject = nil
                    },
                )
            }
#endif
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && parsedStreamURL != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedStreamURL: URL? {
        let raw = streamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    @ViewBuilder
    private var coverPreview: some View {
        HStack(spacing: 16) {
            Group {
#if canImport(UIKit)
                if let pendingCoverData,
                   let uiImage = UIImage(data: pendingCoverData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    RadioStationMeshArtworkView(
                        seedKey: RadioStationMeshArtwork.seedKey(stationId: "preview-\(trimmedName)"),
                        cornerRadius: 12,
                    )
                }
#else
                RadioStationMeshArtworkView(
                    seedKey: RadioStationMeshArtwork.seedKey(stationId: "preview-\(trimmedName)"),
                    cornerRadius: 12,
                )
#endif
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(trimmedName.isEmpty ? "Station name" : trimmedName)
                    .font(.headline)
                Text("Live stream")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func handleCoverPickerSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              !data.isEmpty
        else { return }
#if os(iOS)
        coverCropSubject = RadioCoverCropSubject(imageData: data)
#else
        pendingCoverData = data
#endif
    }

    private func save() async {
        guard let url = parsedStreamURL else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try app.addCustomRadioStation(
                name: trimmedName,
                streamURL: url,
                artworkData: pendingCoverData,
            )
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}
