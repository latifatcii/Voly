import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created only once we know this is the only Voly running: a session
    /// starts discovering and connecting to agents as soon as it exists.
    private var session: InspectorSession?
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        // Render the inspector from fixtures to PNGs and exit. Touches no
        // simulator and no agent, so it is safe next to a running Voly.
        if let directory = environment["VOLY_UI_PREVIEW"] {
            Task { @MainActor in
                await UIPreviewRenderer.run(outputDirectory: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            }
            return
        }
        #endif
        #if DEBUG
        // Scripted smoke runs of a debug build: no modal waiting for a click,
        // and the inspector on screen without the global hotkey.
        let scripted = environment["VOLY_SCRIPTED_RUN"] == "1"
        #else
        let scripted = false
        #endif
        // Two copies would each manage the same simulators and keep undoing
        // each other (e.g. an installed Voly plus a build run from Xcode).
        if let other = Self.otherRunningInstance() {
            NSLog("[Voly] another instance is already running (pid %d) — quitting this one", other.processIdentifier)
            if !scripted {
                let alert = NSAlert()
                alert.messageText = "Voly is already running"
                alert.informativeText = """
                    Another copy of Voly (pid \(other.processIdentifier)) is managing your simulators. \
                    Quit it first if you want to use this one.
                    """
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            NSApp.terminate(nil)
            return
        }

        if !scripted {
            FirstRunAccessibilityPrompt.runIfNeeded()
        }

        let session = InspectorSession()
        self.session = session
        coordinator = AppCoordinator(session: session)
        coordinator?.start()
        session.agentAccess.start(session: session)
        installTerminationSignals()
        if scripted {
            coordinator?.showInspector()
        }
        #if DEBUG
        if scripted, let path = environment["VOLY_SCRIPTED_SNAPSHOT"] {
            installSnapshotSignal(path: path)
        }
        #endif
    }

    #if DEBUG
    private var snapshotSignal: DispatchSourceSignal?

    /// `kill -USR1 <pid>` writes the inspector's current contents to `path`.
    /// Rendered in-process, so it needs no Screen Recording permission.
    private func installSnapshotSignal(path: String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.coordinator?.writeInspectorSnapshot(to: URL(fileURLWithPath: path))
            }
        }
        source.resume()
        snapshotSignal = source
    }
    #endif

    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private var terminationSignals: [DispatchSourceSignal] = []

    /// Voly's launch bridge must not outlive Voly in a simulator, so quitting
    /// first unloads it everywhere. The wait is bounded: a stuck simulator
    /// can't keep the app from quitting.
    func applicationWillTerminate(_ notification: Notification) {
        session?.agentAccess.stop()
        // Android: give back the ports adb forwards to the agents.
        let releaseAndroid = session?.android.prepareReleaseForQuit()
        guard let unload = session?.simulators.prepareUnloadForQuit() else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await unload()
            await releaseAndroid?()
            done.signal()
        }
        _ = done.wait(timeout: .now() + .seconds(8))
    }

    /// `kill` and Ctrl-C get the same cleanup as Quit.
    private func installTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    // Never terminate when the inspector window closes — the menu-bar icon
    // keeps the process alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
