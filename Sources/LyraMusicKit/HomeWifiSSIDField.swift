import SwiftUI

struct HomeWifiSSIDField: View {
    @State private var ssid = ""
    var onAdd: (String) -> Void

    var body: some View {
        HStack {
            TextField("Home Wi‑Fi name (SSID)", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                onAdd(ssid)
                ssid = ""
            }
            .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
