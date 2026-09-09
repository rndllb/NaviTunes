import SwiftUI

/// Navidrome ``createShare`` — copies the server URL to the pasteboard and shows a toast.
struct NavidromeShareMenuSection: View {
    @EnvironmentObject private var app: AppModel
    let itemId: String
    let description: String

    var body: some View {
        if app.canCreateNavidromeShares {
            Section {
                Button {
                    Task { await app.createNavidromeShareAndNotify(forItemId: itemId, description: description) }
                } label: {
                    Label("Create Share Link", systemImage: "link")
                }
            }
            .menuSectionPrimaryTint()
        }
    }
}
