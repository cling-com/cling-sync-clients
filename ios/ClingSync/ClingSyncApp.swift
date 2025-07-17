//
//  ClingSyncApp.swift
//  ClingSync
//
//  Created by Peter Romianowski on 14.07.25.
//

import SwiftUI

@main
struct ClingSyncApp: App {

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset") {
            let bundleIdentifier = Bundle.main.bundleIdentifier!
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            UserDefaults.standard.synchronize()  // Ensure changes are written
            print("UserDefaults cleared.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
