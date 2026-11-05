import SwiftUI

/// Lists nearby Bluetooth devices so any user can pick their own walking pad.
struct DevicePickerView: View {
    let pad: PadConnection
    @Environment(\.dismiss) private var dismiss
    /// Shown when scanning has found no likely pad for a while.
    @State private var showHint = false

    var body: some View {
        NavigationStack {
            List {
                if pad.isDemo {
                    Section {
                        Button("Leave demo mode", role: .destructive) {
                            pad.leaveDemo()
                            dismiss()
                        }
                    } header: {
                        Text("Demo mode is on")
                    } footer: {
                        Text("You are using a simulated pad. Walks are not saved to Apple Health.")
                    }
                }

                if pad.isWalkInProgress {
                    Section { Text("Stop the belt before changing the connection.").font(.footnote) }
                }

                if let saved = pad.savedDevice, !pad.isDemo {
                    Section("Last pad") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(saved.name)
                                Text(statusText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 16) {
                                if pad.isReleased {
                                    Button("Connect") {
                                        pad.reconnect()
                                        dismiss()
                                    }
                                    .buttonStyle(.borderless)
                                } else if pad.state == .connected || pad.state == .connecting || pad.state == .disconnected {
                                    // Not during a walk: the belt would keep running without the app.
                                    Button("Disconnect") { pad.disconnect() }
                                        .buttonStyle(.borderless)
                                        .disabled(pad.isWalkInProgress)
                                }
                                Button("Forget", role: .destructive) { pad.forgetDevice() }
                                    .buttonStyle(.borderless)
                                    .disabled(pad.isWalkInProgress)
                            }
                        }
                    }
                }

                if let error = pad.connectionError {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                // The most common reason for a pad that "cannot be found": something else holds its only connection.
                if showHint, pad.isScanning, !pad.isDemo, pad.state != .connected, !pad.discovered.contains(where: \.looksLikePad) {
                    Section {
                        Label("No walking pad found yet. A pad accepts only one connection, so make sure no other phone or app is connected to it, including Amble on another device.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(pad.discovered) { device in
                        Button {
                            pad.connect(to: device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    if device.looksLikePad {
                                        Text("Possible walking pad").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Image(systemName: signalSymbol(device.rssi)).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(pad.isWalkInProgress)
                    }
                    if pad.discovered.isEmpty {
                        if pad.isScanning {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching...").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Waiting for Bluetooth...").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Nearby devices")
                } footer: {
                    Text("Switch the pad on and close other apps that may be connected to it; a pad accepts only one connection. Only pads with the standard Bluetooth fitness machine profile (FTMS) work with Amble.")
                }

                if !pad.isDemo {
                    Section {
                        Button("Try the demo") {
                            pad.startDemo()
                            dismiss()
                        }
                        .disabled(pad.isWalkInProgress)
                    } header: {
                        Text("No pad at hand?")
                    } footer: {
                        Text("The demo uses a simulated pad so you can look around. Demo walks are not saved to Apple Health.")
                    }
                }
            }
            .navigationTitle("Connect a pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                try? await Task.sleep(for: .seconds(8))
                showHint = true
            }
            .onAppear { pad.startScan() }
            .onDisappear { pad.stopScan() }
        }
    }

    private var statusText: String {
        if pad.isReleased { return String(localized: "Disconnected") }
        return switch pad.state {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting...")
        case .disconnected: String(localized: "Not in range")
        default: String(localized: "Saved")
        }
    }

    private func signalSymbol(_ rssi: Int) -> String {
        switch rssi {
        case ..<(-85): "wifi.exclamationmark"
        case ..<(-70): "wifi"
        default: "wifi"
        }
    }
}
