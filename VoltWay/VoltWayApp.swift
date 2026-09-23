import SwiftUI

@main
struct VoltWayApp: App {
    @State private var store = VoltWayStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(.voltBlue)
                .task { await store.bootstrap() }
        }
    }
}
