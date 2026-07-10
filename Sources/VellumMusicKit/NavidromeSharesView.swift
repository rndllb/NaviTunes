import SwiftUI

struct NavidromeSharesView: View {
    @EnvironmentObject private var app: AppModel
    @State private var shares: [NavidromeShareEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading && shares.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage, shares.isEmpty {
                ContentUnavailableView(
                    "Couldn't load shares",
                    systemImage: "link.badge.plus",
                    description: Text(errorMessage)
                )
            } else if shares.isEmpty {
                ContentUnavailableView(
                    "No shares yet",
                    systemImage: "link",
                    description: Text("Create share links from album, track, or playlist menus when your account has share permissions.")
                )
            } else {
                ForEach(shares) { share in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(share.entry?.title ?? share.description ?? "Share")
                            .font(.body.weight(.semibold))
                        if let artist = share.entry?.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(share.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        if let expires = share.expires {
                            Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        ShareLink(item: share.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            Task { await deleteShare(share) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Share Links")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadShares() }
        .task { await loadShares() }
    }

    private func loadShares() async {
        isLoading = true
        defer { isLoading = false }
        do {
            shares = try await app.fetchNavidromeShares()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteShare(_ share: NavidromeShareEntry) async {
        do {
            try await app.deleteNavidromeShare(id: share.id)
            shares.removeAll { $0.id == share.id }
            app.showTransientToast("Share deleted")
        } catch {
            app.showTransientToast("Couldn't delete share")
        }
    }
}

struct LibraryScanControlsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scanStatus: NavidromeScanStatus?
    @State private var isStarting = false
    @State private var isPolling = false

    var body: some View {
        Group {
            if app.backendKind == .navidrome {
                Section {
                    Button {
                        Task { await startScan() }
                    } label: {
                        HStack {
                            Text("Scan library now")
                            Spacer()
                            if isStarting || isPolling {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isStarting || isPolling)

                    if let scanStatus {
                        HStack {
                            Text("Scan status")
                            Spacer()
                            Text(statusLabel(scanStatus))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Library Scan")
                } footer: {
                    Text("Triggers a Navidrome media scan so new files on disk appear in the catalog.")
                }
            }
        }
    }

    private func startScan() async {
        isStarting = true
        defer { isStarting = false }
        do {
            try await app.triggerServerLibraryScan()
            app.showTransientToast("Library scan started")
            await pollScanStatus()
        } catch {
            app.showTransientToast("Couldn't start scan")
        }
    }

    private func pollScanStatus() async {
        isPolling = true
        defer { isPolling = false }
        for _ in 0..<30 {
            if let status = try? await app.fetchNavidromeScanStatus() {
                scanStatus = status
                if !status.scanning { return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func statusLabel(_ status: NavidromeScanStatus) -> String {
        if status.scanning {
            if status.total > 0 {
                return "Scanning \(status.count)/\(status.total)"
            }
            return "Scanning…"
        }
        return "Idle"
    }
}
