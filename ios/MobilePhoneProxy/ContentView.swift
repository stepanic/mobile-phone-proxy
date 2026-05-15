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
                }

                if server.isRunning {
                    Section("Use from Mac") {
                        let url = "http://\(server.localIP):\(server.port)"
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("export https_proxy=\(url)\nexport http_proxy=\(url)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
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
