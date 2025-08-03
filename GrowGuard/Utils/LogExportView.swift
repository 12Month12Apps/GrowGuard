//
//  LogExportView.swift
//  GrowGuard
//
//  Created for beta testing support
//

import SwiftUI

struct LogExportView: View {
    @State private var isExporting = false
    @State private var exportedLogURL: URL?
    @State private var showShareSheet = false
    @State private var logHours = 24
    @State private var showSuccessAlert = false
    @State private var errorMessage: String?
    
    let logHourOptions = [6, 12, 24, 48, 72]
    
    var body: some View {
        Form {
            Section(header: Text("Debug Log Export")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export app logs for debugging and support")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Log Duration:")
                        Spacer()
                        Picker("Hours", selection: $logHours) {
                            ForEach(logHourOptions, id: \.self) { hours in
                                Text("\(hours)h").tag(hours)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Button(action: exportLogs) {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text(isExporting ? "Exporting..." : "Export Logs")
                        }
                    }
                    .disabled(isExporting)
                    .buttonStyle(.borderedProminent)
                    
                    if let url = exportedLogURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log file exported:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.blue)
                                .onTapGesture {
                                    showShareSheet = true
                                }
                        }
                    }
                }
            }
            
            Section(header: Text("Quick Actions")) {
                Button("Test BLE Connection") {
                    AppLogger.ble.info("🧪 Manual BLE connection test initiated by user")
                }
                
                Button("Log Device Info") {
                    logDeviceInformation()
                }
                
                Button("Clear Exported Logs") {
                    clearExportedLogs()
                }
                .foregroundColor(.red)
            }
            
            Section(footer: Text("Logs contain BLE communication, sensor data, and error information. No personal data is included.")) {
                EmptyView()
            }
        }
        .navigationTitle("Debug Tools")
        .alert("Export Successful", isPresented: $showSuccessAlert) {
            Button("Share") { showShareSheet = true }
            Button("OK") { }
        } message: {
            Text("Debug logs have been exported and are ready to share.")
        }
        .alert("Export Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedLogURL {
                ShareSheet(items: [url])
            }
        }
    }
    
    private func exportLogs() {
        isExporting = true
        errorMessage = nil
        
        Task {
            do {
                let logURL = await AppLogger.exportLogsForSharing(lastHours: logHours)
                
                await MainActor.run {
                    if let url = logURL {
                        exportedLogURL = url
                        showSuccessAlert = true
                        AppLogger.general.info("✅ Log export completed: \(url.lastPathComponent)")
                    } else {
                        errorMessage = "Failed to export logs. Please try again."
                        AppLogger.general.error("❌ Log export failed")
                    }
                    isExporting = false
                }
            }
        }
    }
    
    private func logDeviceInformation() {
        let device = UIDevice.current
        AppLogger.general.info("📱 Device Info - Model: \(device.model), iOS: \(device.systemVersion), Name: \(device.name)")
        AppLogger.general.info("📱 App Info - Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"), Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")")
    }
    
    private func clearExportedLogs() {
        if let url = exportedLogURL {
            try? FileManager.default.removeItem(at: url)
            exportedLogURL = nil
            AppLogger.general.info("🗑️ Exported log files cleared by user")
        }
    }
}

// Share Sheet for iOS
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationView {
        LogExportView()
    }
}