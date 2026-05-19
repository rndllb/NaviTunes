import SwiftUI

@Observable
final class MiniPlayerCollapseState {
    var isCollapsed = false

    func collapse() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isCollapsed = true }
    }

    func expand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isCollapsed = false }
    }
}
