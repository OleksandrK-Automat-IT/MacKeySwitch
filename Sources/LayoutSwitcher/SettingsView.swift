import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            DetectionTab(settings: settings)
                .tabItem {
                    Label("Detection", systemImage: "waveform")
                }

            PerAppTab(settings: settings)
                .tabItem {
                    Label("Per-App Rules", systemImage: "app.badge.checkmark")
                }

            DictionaryTab(settings: settings)
                .tabItem {
                    Label("Dictionary", systemImage: "book")
                }

            StatisticsTab(settings: settings)
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 420)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable automatic layout switching", isOn: $settings.isEnabled)

                Toggle("Start at login", isOn: $settings.autoStartOnLogin)

                Toggle("Show notification on switch", isOn: $settings.showNotifications)
            } header: {
                Text("General")
            }

            Section {
                HStack {
                    Text("Current layout:")
                    Spacer()
                    Text(InputSourceManager.currentLanguage()?.rawValue.capitalized ?? "Other")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Supported pair:")
                    Spacer()
                    Text("Ukrainian \u{2194} English")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Detection Tab

struct DetectionTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Sensitivity", selection: $settings.sensitivity) {
                    ForEach(SettingsModel.Sensitivity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text("Higher sensitivity = more aggressive switching. Lower = fewer false positives.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Detection Sensitivity")
            }

            Section {
                HStack {
                    Text("Correction delay:")
                    Spacer()
                    Text("\(settings.correctionDelayMs) ms")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { Double(settings.correctionDelayMs) },
                        set: { settings.correctionDelayMs = Int($0) }
                    ),
                    in: 10...200,
                    step: 10
                )

                Text("Delay between deleting wrong text and retyping. Increase if corrections appear garbled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Correction Timing")
            }

            Section {
                Stepper("Minimum word length: \(settings.minWordLength)",
                        value: $settings.minWordLength,
                        in: 2...5)

                Text("Words shorter than this won't trigger auto-switching.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Word Length")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Per-App Rules Tab

struct PerAppTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded apps won't trigger automatic layout switching.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(Array(settings.appRules.enumerated()), id: \.element.id) { index, rule in
                    HStack {
                        if let icon = NSWorkspace.shared.icon(forFile:
                            NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: rule.bundleID
                            )?.path ?? ""
                        ) as NSImage? {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }

                        Text(rule.name)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { rule.isExcluded },
                            set: { newValue in
                                settings.appRules[index].isExcluded = newValue
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .onDelete { indexSet in
                    settings.appRules.remove(atOffsets: indexSet)
                }
            }
            .listStyle(.bordered)

            HStack {
                Button("Add Running App...") {
                    addRunningApps()
                }

                Button("Add App from Finder...") {
                    showingAppPicker = true
                }

                Spacer()

                Button("Remove All") {
                    settings.appRules.removeAll()
                }
                .disabled(settings.appRules.isEmpty)
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showingAppPicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                addAppFromURL(url)
            }
        }
    }

    private func addRunningApps() {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> SettingsModel.AppRule? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                // Skip if already in list
                if settings.appRules.contains(where: { $0.bundleID == bundleID }) {
                    return nil
                }
                return SettingsModel.AppRule(bundleID: bundleID, name: name, isExcluded: true)
            }
        settings.appRules.append(contentsOf: runningApps)
    }

    private func addAppFromURL(_ url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        let name = bundle.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        if !settings.appRules.contains(where: { $0.bundleID == bundleID }) {
            settings.appRules.append(
                SettingsModel.AppRule(bundleID: bundleID, name: name, isExcluded: true)
            )
        }
    }
}

// MARK: - Dictionary Tab

struct DictionaryTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var newEnglishWord = ""
    @State private var newUkrainianWord = ""
    @State private var showingEnglishFilePicker = false
    @State private var showingUkrainianFilePicker = false
    @State private var importStatusMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // English column
                VStack(alignment: .leading) {
                    Text("English Words")
                        .font(.headline)

                    List {
                        ForEach(settings.customEnglishWords, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { indexSet in
                            settings.customEnglishWords.remove(atOffsets: indexSet)
                        }
                    }
                    .listStyle(.bordered)

                    HStack {
                        TextField("New word...", text: $newEnglishWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addEnglishWord() }

                        Button("+") { addEnglishWord() }
                            .disabled(newEnglishWord.isEmpty)
                    }

                    Button("Import Dictionary File...") {
                        showingEnglishFilePicker = true
                    }
                    .font(.caption)
                }

                // Ukrainian column
                VStack(alignment: .leading) {
                    Text("Ukrainian Words")
                        .font(.headline)

                    List {
                        ForEach(settings.customUkrainianWords, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { indexSet in
                            settings.customUkrainianWords.remove(atOffsets: indexSet)
                        }
                    }
                    .listStyle(.bordered)

                    HStack {
                        TextField("Нове слово...", text: $newUkrainianWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addUkrainianWord() }

                        Button("+") { addUkrainianWord() }
                            .disabled(newUkrainianWord.isEmpty)
                    }

                    Button("Import Dictionary File...") {
                        showingUkrainianFilePicker = true
                    }
                    .font(.caption)
                }
            }

            // Imported dictionary files
            if !settings.customEnglishDictionaryPaths.isEmpty || !settings.customUkrainianDictionaryPaths.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported Dictionary Files")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(settings.customEnglishDictionaryPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "doc.text")
                            Text("EN: \(URL(fileURLWithPath: path).lastPathComponent)")
                                .font(.caption)
                            Spacer()
                            Button(role: .destructive) {
                                settings.customEnglishDictionaryPaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(settings.customUkrainianDictionaryPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "doc.text")
                            Text("UA: \(URL(fileURLWithPath: path).lastPathComponent)")
                                .font(.caption)
                            Spacer()
                            Button(role: .destructive) {
                                settings.customUkrainianDictionaryPaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !importStatusMessage.isEmpty {
                Text(importStatusMessage)
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showingEnglishFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importDictionaryFile(url: url, language: .english)
            }
        }
        .fileImporter(
            isPresented: $showingUkrainianFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importDictionaryFile(url: url, language: .ukrainian)
            }
        }
    }

    private func importDictionaryFile(url: URL, language: Language) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let count = DictionaryManager.shared.loadDictionaryFile(url: url, language: language)

        // Save path for reloading on next launch
        switch language {
        case .english:
            if !settings.customEnglishDictionaryPaths.contains(url.path) {
                settings.customEnglishDictionaryPaths.append(url.path)
            }
        case .ukrainian:
            if !settings.customUkrainianDictionaryPaths.contains(url.path) {
                settings.customUkrainianDictionaryPaths.append(url.path)
            }
        }

        importStatusMessage = "Imported \(count) \(language.rawValue) words from \(url.lastPathComponent)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            importStatusMessage = ""
        }
    }

    private func addEnglishWord() {
        let word = newEnglishWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !settings.customEnglishWords.contains(word) else { return }
        settings.customEnglishWords.append(word)
        newEnglishWord = ""
    }

    private func addUkrainianWord() {
        let word = newUkrainianWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !settings.customUkrainianWords.contains(word) else { return }
        settings.customUkrainianWords.append(word)
        newUkrainianWord = ""
    }
}

// MARK: - Statistics Tab

struct StatisticsTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Total corrections (all time):")
                    Spacer()
                    Text("\(settings.totalCorrections)")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Corrections this session:")
                    Spacer()
                    Text("\(settings.sessionCorrections)")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Correction Statistics")
            }

            Section {
                if settings.exceptionWords.isEmpty {
                    Text("No learned exceptions yet. Backspace after a wrong correction to teach the app.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(settings.exceptionWords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { indexSet in
                        settings.exceptionWords.remove(atOffsets: indexSet)
                    }
                }
            } header: {
                Text("Self-Learned Exceptions (\(settings.exceptionWords.count))")
            }

            Section {
                Button("Clear Exception Words") {
                    settings.exceptionWords.removeAll()
                }
                .disabled(settings.exceptionWords.isEmpty)

                Button("Reset Statistics") {
                    settings.resetStatistics()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About Tab

/// Diagonal clip shape for the Union Jack half
struct DiagonalClip: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

/// Simplified Union Jack drawn with SwiftUI shapes
struct UnionJackView: View {
    let ukNavy = Color(red: 0.0, green: 0.13, blue: 0.40)
    let ukRed = Color(red: 0.81, green: 0.06, blue: 0.13)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Navy background
                Rectangle().fill(ukNavy)

                // White diagonal stripes
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.12, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h * 0.88))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.88, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.12))
                    p.closeSubpath()
                }.fill(Color.white)
                Path { p in
                    p.move(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.88, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.88))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w * 0.12, y: h))
                    p.addLine(to: CGPoint(x: w, y: h * 0.12))
                    p.closeSubpath()
                }.fill(Color.white)

                // Red diagonal stripes (thinner)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.05, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h * 0.95))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.95, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.05))
                    p.closeSubpath()
                }.fill(ukRed)
                Path { p in
                    p.move(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.95, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.95))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w * 0.05, y: h))
                    p.addLine(to: CGPoint(x: w, y: h * 0.05))
                    p.closeSubpath()
                }.fill(ukRed)

                // White cross
                Rectangle().fill(Color.white)
                    .frame(width: w * 0.2, height: h)
                Rectangle().fill(Color.white)
                    .frame(width: w, height: h * 0.2)

                // Red cross
                Rectangle().fill(ukRed)
                    .frame(width: w * 0.11, height: h)
                Rectangle().fill(ukRed)
                    .frame(width: w, height: h * 0.11)
            }
        }
    }
}

/// Combined UK + Ukraine flag icon using SwiftUI shapes
struct CombinedFlagIcon: View {
    let size: CGFloat
    private var flagHeight: CGFloat { size * 0.67 }

    let uaBlue = Color(red: 0.0, green: 0.35, blue: 0.73)
    let uaYellow = Color(red: 1.0, green: 0.84, blue: 0.0)

    var body: some View {
        ZStack {
            // Ukrainian flag — full background
            VStack(spacing: 0) {
                Rectangle().fill(uaBlue)
                Rectangle().fill(uaYellow)
            }

            // Union Jack — clipped to top-left triangle
            UnionJackView()
                .clipShape(DiagonalClip())

            // Diagonal white divider
            Path { path in
                path.move(to: CGPoint(x: size, y: 0))
                path.addLine(to: CGPoint(x: 0, y: flagHeight))
            }
            .stroke(Color.white, lineWidth: 2.5)

            // Keyboard icon
            Image(systemName: "keyboard")
                .font(.system(size: size * 0.18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
        }
        .frame(width: size, height: flagHeight)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.06))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.06)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .allowsHitTesting(false)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            // Combined UK + Ukraine flag icon
            CombinedFlagIcon(size: 90)
                .padding(.top, 8)

            Text("MacKeySwitch")
                .font(.system(size: 22, weight: .bold))

            Text("Automatic Mac Keyboard Switcher")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Text("Version 2.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Divider().frame(width: 250)

            // Bilingual description
            VStack(spacing: 3) {
                Text("Automatic keyboard layout switcher for Ukrainian and English.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Automatically detects the wrong layout and corrects text in real time.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider().frame(width: 250)

            VStack(spacing: 3) {
                Text("\u{0410}\u{0432}\u{0442}\u{043E}\u{043C}\u{0430}\u{0442}\u{0438}\u{0447}\u{043D}\u{0435} \u{043F}\u{0435}\u{0440}\u{0435}\u{043C}\u{0438}\u{043A}\u{0430}\u{043D}\u{043D}\u{044F} \u{0440}\u{043E}\u{0437}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}\u{0438} \u{043A}\u{043B}\u{0430}\u{0432}\u{0456}\u{0430}\u{0442}\u{0443}\u{0440}\u{0438} \u{043C}\u{0456}\u{0436} \u{0443}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{043E}\u{044E} \u{0442}\u{0430} \u{0430}\u{043D}\u{0433}\u{043B}\u{0456}\u{0439}\u{0441}\u{044C}\u{043A}\u{043E}\u{044E} \u{043C}\u{043E}\u{0432}\u{0430}\u{043C}\u{0438}.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("\u{0410}\u{0432}\u{0442}\u{043E}\u{043C}\u{0430}\u{0442}\u{0438}\u{0447}\u{043D}\u{043E} \u{0432}\u{0438}\u{0437}\u{043D}\u{0430}\u{0447}\u{0430}\u{0454} \u{043D}\u{0435}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B}\u{044C}\u{043D}\u{0443} \u{0440}\u{043E}\u{0437}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}\u{0443} \u{0442}\u{0430} \u{0432}\u{0438}\u{043F}\u{0440}\u{0430}\u{0432}\u{043B}\u{044F}\u{0454} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0443} \u{0440}\u{0435}\u{0430}\u{043B}\u{044C}\u{043D}\u{043E}\u{043C}\u{0443} \u{0447}\u{0430}\u{0441}\u{0456}.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 3) {
                Text("Created by Oleksandr Kuzmin, 2026")
                    .font(.system(size: 11, weight: .medium))

                Text("Licensed under GNU General Public License v3.0 (GPL-3.0)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}
