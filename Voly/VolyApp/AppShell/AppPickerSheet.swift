// Voly/VolyApp/AppShell/AppPickerSheet.swift
import SwiftUI
import VolyHost

struct AppPickerSheet: View {
    let dylibURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [SimDevice] = []
    @State private var selectedDevice: SimDevice?
    @State private var apps: [SimApp] = []
    @State private var selectedApp: SimApp?
    @State private var isLoadingDevices = false
    @State private var isLoadingApps = false
    @State private var isLaunching = false
    @State private var errorMessage: String?

    private let inventory = SimInventory()
    private let launcher = SimctlLauncher()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                deviceList
                    .frame(minWidth: 220)
                appList
                    .frame(minWidth: 320)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            await loadDevices()
        }
    }

    private var header: some View {
        HStack {
            Text("Attach to app…").font(.title3).bold()
            Spacer()
        }
        .padding(12)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Booted simulators")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            List(selection: $selectedDevice) {
                ForEach(devices) { d in
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text(d.runtime).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(Optional(d))
                }
            }
            .onChange(of: selectedDevice) { _, newDevice in
                apps = []
                guard let newDevice else { return }
                Task { await loadApps(for: newDevice) }
            }
            if isLoadingDevices {
                ProgressView().controlSize(.small).padding(.bottom, 8)
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Installed apps")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            if apps.isEmpty && !isLoadingApps {
                ContentUnavailableView(
                    selectedDevice == nil ? "Select a device" : "No installed apps",
                    systemImage: "square.dashed"
                )
            } else {
                List(selection: $selectedApp) {
                    ForEach(apps) { a in
                        VStack(alignment: .leading) {
                            Text(a.displayName)
                            Text(a.bundleIdentifier).font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(Optional(a))
                    }
                }
            }
            if isLoadingApps {
                ProgressView().controlSize(.small).padding(.bottom, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await attach() }
            } label: {
                if isLaunching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Attach")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedDevice == nil || selectedApp == nil || isLaunching)
        }
        .padding(12)
    }

    private func loadDevices() async {
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            devices = try await inventory.listDevices(bootedOnly: true)
            if selectedDevice == nil { selectedDevice = devices.first }
        } catch {
            errorMessage = "Failed to list devices: \(error)"
        }
    }

    private func loadApps(for device: SimDevice) async {
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            apps = try await inventory.listApps(deviceUDID: device.udid, includeSystem: false)
        } catch {
            errorMessage = "Failed to list apps: \(error)"
        }
    }

    private func attach() async {
        guard let device = selectedDevice, let app = selectedApp else { return }
        isLaunching = true
        defer { isLaunching = false }
        do {
            _ = try await launcher.launch(
                deviceUDID: device.udid,
                bundleIdentifier: app.bundleIdentifier,
                dylibPath: dylibURL
            )
            dismiss()
        } catch {
            errorMessage = "Launch failed: \(error)"
        }
    }
}
