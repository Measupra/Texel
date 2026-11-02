import SwiftUI

@main
struct TexelPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // One window is enough for Texel.
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
