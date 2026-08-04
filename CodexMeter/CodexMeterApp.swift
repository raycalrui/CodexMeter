//
//  CodexMeterApp.swift
//  CodexMeter
//
//  Created by raycal on 8/5/26.
//

import SwiftUI

@main
struct CodexMeterApp: App {
    @StateObject private var usageService = CodexUsageService()

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: usageService.menuBarSymbol)
                Text(usageService.menuBarTitle)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
