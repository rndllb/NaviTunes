import SwiftUI

struct NowPlayingDismissHost<Content: View>: View {
    @Binding var isPresented: Bool
    private let content: () -> Content

    init(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        _isPresented = isPresented
        self.content = content
    }

    var body: some View { content() }
}
