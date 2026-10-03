import SwiftUI

struct ModelDrawer: View {
    @Environment(\.dismiss) private var dismiss
    /// Which tab opens first: LLM from the model button.
    var tab: ModelsTab = .llm
    var body: some View {
        NavigationStack {
            ModelConnectionsView(tab: tab)
                .navigationTitle("Models").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }
    }
}

struct NearbyKemosPanel: View {
    @Environment(AppStore.self) private var store
    @State private var nearby: NearbyKemos?
    var body: some View {
        Group {
            if let nearby { NearbyKemosView(nearby: nearby) }
            else { KemoOrb(size: 28).task {
                let next = NearbyKemos(displayName: CompanionIdentity.name) { [store] request in
                    return try await store.replyToNearby(request)
                }
                #if DEBUG
                if NearbyKemosFixture.requested { NearbyKemosFixture.install(next) }
                #endif
                nearby = next
            } }
        }
    }
}
