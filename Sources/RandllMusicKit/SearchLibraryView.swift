import SwiftUI

/// Search tab: Lidarr vs Library scopes (see `DiscoverySearchView`).
struct SearchLibraryView: View {
    var body: some View {
        NavigationStack {
            DiscoverySearchView()
        }
        .tint(MusicDesign.accent)
    }
}
