import SwiftUI
import VisionKit

struct SettingsScreen: View {
    @EnvironmentObject private var store: Store
    @State private var scanning = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var problem: String?

    /// Colours for new projects, the Mac's sand colours first.
    private static let palette = ["#6C2ED6", "#34BEA6", "#EC62A0", "#2876E2", "#E8833A", "#3FA34D", "#D4B106", "#8E5A3C", "#C2410C", "#475569"]

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                Section {
                    ForEach(store.projects.visible, id: \.id) { project in ProjectRow(project: project, palette: Self.palette) }
                    Button("Add Project") {
                        var list = store.projects
                        let used = Set(list.visible.map(\.color))
                        let color = Self.palette.first { !used.contains($0) } ?? Self.palette[list.all.count % Self.palette.count]
                        list.all.append(Project(name: "Project \(list.visible.count + 1)", color: color))
                        store.updateProjects(list)
                    }
                } header: { Text("Projects") } footer: { Text("Time counts toward the project that's on.") }

                Section {
                    Toggle("Aim for a daily target", isOn: Binding(get: { store.targetMinutes > 0 }, set: { store.targetMinutes = $0 ? 60 : 0 }))
                    if store.targetMinutes > 0 {
                        Stepper("\(SandLog.durationLabel(Double(store.targetMinutes * 60))) a day", value: $store.targetMinutes, in: 15...720, step: 15)
                    }
                } header: { Text("Daily target") } footer: { Text("A groove along the base fills with sand as the day's time runs.") }

                Section {
                    Toggle("Chime when the time is up", isOn: $store.chime)
                    Toggle("One Thing at a Time", isOn: $store.oneThingAtATime)
                    Toggle("Keep the screen on", isOn: $store.keepScreenOn)
                } header: { Text("Timer") } footer: { Text("One Thing at a Time keeps the project for the whole session. End the session to switch. The screen stays on while the sand runs and the timer is showing.") }

                Section {
                    Text("Sand Timer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""). Your time stays on this phone unless you link it to your Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ink)
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $scanning) {
            Scanner { code in
                scanning = false
                link(code)
            }
            .ignoresSafeArea()
        }
        .alert("Paste the Mac's code", isPresented: $pasting) {
            TextField("sandtimer-link:…", text: $pasted)
            Button("Link") { link(pasted) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Linking to a Mac, like linking a phone to a messaging account: scan the Mac's code, and share from then on.
    /// Off until turned on here, and only then does the app ask for Bluetooth.
    @ViewBuilder private var linkSection: some View {
        Section {
            Toggle("Link to a Mac", isOn: Binding(get: { store.linkEnabled }, set: { LinkClient.engine.setEnabled($0) }))
            if store.linkEnabled && !store.linked {
                Text("On the Mac, open Sand Timer's Settings, turn on Link with a phone, click Link a Phone…, then scan the code it shows.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Scan the Mac's Code") {
                    problem = nil
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable { scanning = true } else { pasting = true }
                }
            } else if store.linkEnabled {
                if store.devices.isEmpty { Text("Linked. Looking for your Mac nearby…").foregroundStyle(.secondary) }
                ForEach(store.devices, id: \.id) { device in
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(store.connected.contains(device.id) ? "Connected"
                             : "Last seen \(device.seen.formatted(.relative(presentation: .named)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Unlink This Phone", role: .destructive) { LinkClient.engine.unlink() }
            }
            if let message = problem ?? store.linkProblem {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: { Text("Link to a Mac") } footer: {
            Text("Optional: share one timer, your projects and statistics with Sand Timer on your Mac. The two talk over Bluetooth, encrypted, whenever they're near each other.")
        }
    }

    private func link(_ code: String) {
        do { try LinkClient.engine.link(code: code) } catch { problem = error.localizedDescription }
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var store: Store
    let project: Project
    let palette: [String]
    @State private var name = ""

    var body: some View {
        HStack {
            Menu {
                ForEach(palette, id: \.self) { hex in
                    Button { change { $0.color = hex } } label: {
                        Label(hex, systemImage: hex.caseInsensitiveCompare(project.color) == .orderedSame ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(Color(uiColor: UIColor(hex: hex) ?? .gray))
                }
            } label: {
                Circle().fill(Color(uiColor: UIColor(hex: project.color) ?? .gray)).frame(width: 24, height: 24)
            }
            TextField("Project name", text: $name)
                .onSubmit { commit() }
                .onChange(of: name) { commit() }
            Button(role: .destructive) { change { $0.archived = true } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
        .onAppear { name = project.name }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        change { $0.name = trimmed }
    }

    private func change(_ edit: (inout Project) -> Void) {
        var list = store.projects
        guard let index = list.all.firstIndex(where: { $0.id == project.id }) else { return }
        edit(&list.all[index])
        store.updateProjects(list)
    }
}

/// The camera, looking for the Mac's QR code.
struct Scanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, text.hasPrefix(LinkFormat.codePrefix) else { continue }
                done = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
