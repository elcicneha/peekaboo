//
//  QuickLookCodeApp.swift
//  QuickLookCode
//
//  Created by Neha Gupta on 14/04/26.
//

import SwiftUI
import QuickLookCodeShared

@main
struct QuickLookCodeApp: App {

    init() {
        // Build the disk cache in the background at launch so it's ready before
        // the user opens a Quick Look preview for the first time.
        Task.detached(priority: .background) {
            CacheManager.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
