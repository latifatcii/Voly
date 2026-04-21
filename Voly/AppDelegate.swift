//
//  AppDelegate.swift
//  Voly
//
//  Created by Latif Atci on 21.04.2026.
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ aNotification: Notification) {}
    // Return false so SwiftUI always opens a fresh window on launch, instead of
    // trying to restore a (possibly stale / off-screen) saved window frame.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

