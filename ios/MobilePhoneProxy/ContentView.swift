import SwiftUI

struct ContentView: View {
    @EnvironmentObject var server: ProxyServer
    @State private var portText: String = "8888"

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    HStack {
                        Circle()
                            .fill(server.isRunning ? .green : .gray)
                            .frame(width: 10, height: 10)
                        Text(server.isRunning ? "Running" : "Stopped")
                            .font(.headline)
                        Spacer()
                        Text("\(server.activeConnections) active")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    LabeledContent("WiFi IP", value: server.localIP)
                    LabeledContent("Cellular IP", value: server.cellularIP)
                    LabeledContent("Tailscale IP", value: server.tailscaleIP)
                    LabeledContent("Bytes ↑", value: ByteCountFormatter.string(fromByteCount: Int64(server.bytesUp), countStyle: .binary))
                    LabeledContent("Bytes ↓", value: ByteCountFormatter.string(fromByteCount: Int64(server.bytesDown), countStyle: .binary))
                }

                Section("Proxy") {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .disabled(server.isRunning)
                            .frame(width: 100)
                    }
                    if server.isRunning {
                        Button(role: .destructive) {
                            server.stop()
                        } label: {
                            Label("Stop proxy", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            if let p = UInt16(portText) { server.port = p }
                            server.start()
                        } label: {
                            Label("Start proxy", systemImage: "play.fill")
                        }
                    }

                    Toggle(isOn: $server.keepAliveEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep alive in background (audio)")
                            Text("Plays silent audio so the proxy survives screen-lock. Costs battery; may pause on a call.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: server.keepAliveEnabled) { _ in
                        server.updateKeepAlive()
                    }
                }

                if server.isRunning {
                    // Remote (parked) model reaches the phone over the tailnet;
                    // LAN model uses the WiFi IP. Prefer whichever is present,
                    // Tailscale first since that's the remote use case.
                    let host = server.tailscaleIP != "—" ? server.tailscaleIP
                             : (server.localIP != "—" ? server.localIP : "<phone-ip>")
                    let url = "http://\(host):\(server.port)"
                    Section("Use from Mac") {
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("export https_proxy=\(url)\nexport http_proxy=\(url)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    Section("Parked node (remote)") {
                        Label {
                            Text("Tailscale ON · WiFi OFF · screen on · on charger")
                        } icon: {
                            Image(systemName: "bolt.fill")
                        }
                        .font(.caption)
                        if server.localIP != "—" {
                            Label {
                                Text("WiFi is ON — egress will use WiFi/home IP, not cellular. Turn WiFi OFF.")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        if server.tailscaleIP == "—" {
                            Label {
                                Text("No tailnet IP — start Tailscale so the Mac can reach this phone remotely.")
                            } icon: {
                                Image(systemName: "network.slash")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Log") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(server.log.suffix(60).reversed(), id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            .navigationTitle("Mobile Phone Proxy")
        }
    }
}
