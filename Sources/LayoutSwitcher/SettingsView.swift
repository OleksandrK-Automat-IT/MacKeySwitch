import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// The tab view's own size, before the window padding around it.
    ///
    /// Wide enough for the longest set of tab titles across every shipped language.
    ///
    /// Measured, not guessed: `SettingsLayoutTests` lays the real strings out in the system
    /// font and fails if they do not fit. The custom tab bar keeps every title on one line
    /// in both shipped languages.
    ///
    /// The height fits the General tab, the tallest, without scrolling — checked by
    /// rendering it, since a Form's height is not something a string measurement predicts.
    static let contentSize = NSSize(width: 740, height: 560)

    /// Margin between the tab view and the window edge. Also the room the focus ring needs:
    /// it is drawn *outside* the control's bounds, so a frame flush against the window would
    /// clip it.
    static let windowPadding: CGFloat = 16

    /// The custom tab bar and its selected segment share this exact height. AppKit's
    /// segmented tab style draws the blue selection with an internal inset, leaving a pale
    /// strip around it; using one metric for both removes that unwanted gap.
    static let tabBarHeight: CGFloat = 26
    static let tabCornerRadius: CGFloat = 7
    static let selectedTabInset: CGFloat = 0

    /// Single source of truth for the settings window size — AppDelegate sizes the window
    /// from this rather than repeating the numbers.
    static let preferredSize = NSSize(
        width: contentSize.width + windowPadding * 2,
        height: contentSize.height + windowPadding * 2
    )

    @ObservedObject var settings: SettingsModel
    /// Observed so every label re-renders the moment the interface language changes —
    /// switching language should not require reopening the window.
    @ObservedObject private var l10n = Localization.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 12) {
            SettingsTabBar(selection: $selectedTab)

            // Keep every tab mounted so local view state (partially entered dictionary
            // words, an open picker, etc.) survives switching tabs. Only the selected view
            // participates in interaction and accessibility.
            ZStack(alignment: .top) {
                GeneralTab(settings: settings)
                    .settingsTabVisibility(selectedTab == .general)

                DetectionTab(settings: settings)
                    .settingsTabVisibility(selectedTab == .detection)

                PerAppTab(settings: settings)
                    .settingsTabVisibility(selectedTab == .perApp)

                DictionaryTab(settings: settings)
                    .settingsTabVisibility(selectedTab == .dictionary)

                StatisticsTab(settings: settings)
                    .settingsTabVisibility(selectedTab == .statistics)

                AboutTab()
                    .settingsTabVisibility(selectedTab == .about)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A minimum rather than a fixed size: a longer translation makes the tab bar grow
        // instead of truncating its titles.
        .frame(
            minWidth: Self.contentSize.width,
            idealWidth: Self.contentSize.width,
            minHeight: Self.contentSize.height,
            idealHeight: Self.contentSize.height
        )
        .padding(Self.windowPadding)
    }
}

// MARK: - Settings Tab Bar

enum SettingsTab: Int, CaseIterable, Identifiable {
    case general
    case detection
    case perApp
    case dictionary
    case statistics
    case about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return L("tab.general")
        case .detection: return L("tab.detection")
        case .perApp: return L("tab.perApp")
        case .dictionary: return L("tab.dictionary")
        case .statistics: return L("tab.statistics")
        case .about: return L("tab.about")
        }
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @ObservedObject private var l10n = Localization.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: SettingsView.tabBarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // These buttons already expose their selected state and are operated as one
                // tab group. Letting AppKit keep keyboard focus on the first button draws a
                // second blue outline after another tab is selected, making two tabs look
                // active at once.
                .focusable(false)
                .foregroundStyle(selection == tab ? Color.white : Color.primary)
                .background {
                    if selection == tab {
                        RoundedRectangle(
                            cornerRadius: SettingsView.tabCornerRadius,
                            style: .continuous
                        )
                        .fill(Color.accentColor)
                        .padding(SettingsView.selectedTabInset)
                    }
                }
                .accessibilityAddTraits(selection == tab ? .isSelected : [])

                if tab != SettingsTab.allCases.last {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: 14)
                        // No pale one-pixel gutter beside the selected segment.
                        .opacity(separatorTouchesSelection(after: tab) ? 0 : 1)
                }
            }
        }
        .frame(height: SettingsView.tabBarHeight)
        .background(Color.primary.opacity(0.065))
        .clipShape(
            RoundedRectangle(
                cornerRadius: SettingsView.tabCornerRadius,
                style: .continuous
            )
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }

    private func separatorTouchesSelection(after tab: SettingsTab) -> Bool {
        guard let index = SettingsTab.allCases.firstIndex(of: tab),
              index + 1 < SettingsTab.allCases.count else { return false }
        return selection == tab || selection == SettingsTab.allCases[index + 1]
    }
}

private extension View {
    func settingsTabVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject private var l10n = Localization.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("general.enable"), isOn: $settings.isEnabled)

                Toggle(L("general.startAtLogin"), isOn: $settings.autoStartOnLogin)

                Toggle(L("general.showNotifications"), isOn: $settings.showNotifications)

                // In the General section rather than one of its own: a section header plus
                // its spacing costs ~90pt, which pushed the rest of this tab below the fold
                // for the sake of a single picker.
                Picker(L("general.language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Text(L("general.languageHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L("general.section"))
            }

            Section {
                HotkeyRecorderRow(settings: settings)
                Text(L("hotkey.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L("hotkey.section"))
            }

            Section {
                HStack {
                    Text(L("status.currentLayout"))
                    Spacer()
                    Text(LayoutFlag.currentLayoutDisplayName)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text(L("status.supportedPair"))
                    Spacer()
                    Text(L("status.pair"))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L("status.section"))
            }
        }
        .formStyle(.grouped)
    }


}

// MARK: - Hotkey Recorder

/// Row that shows the current undo hotkey and lets the user re-record it.
/// While "Record" is active, an NSEvent local monitor captures the next keyDown
/// and stores its keyCode + modifier flags. Esc cancels, Delete disables.
struct HotkeyRecorderRow: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject private var l10n = Localization.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(L("hotkey.label"))
            Spacer()

            Button(action: toggleRecording) {
                Text(isRecording ? L("hotkey.recording") : settings.undoHotkey.description)
                    .monospacedDigit()
                    .frame(minWidth: 140)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)

            Button {
                settings.undoHotkey = .disabled
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("hotkey.disable"))
            .disabled(!settings.undoHotkey.isEnabled)
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event: event)
            return nil // swallow the key so it doesn't leak into fields
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handle(event: NSEvent) {
        let kc = event.keyCode
        // Esc cancels
        if kc == 0x35 {
            stopRecording()
            return
        }
        // Delete/Backspace disables
        if kc == 0x33 {
            settings.undoHotkey = .disabled
            stopRecording()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meaningful = flags.intersection([.control, .option, .shift, .command])
        // Require at least one non-shift modifier — bare 'Z' or '⇧Z' would eat typing.
        let nonShift: NSEvent.ModifierFlags = [.control, .option, .command]
        guard !meaningful.isDisjoint(with: nonShift) else { return }
        // Keycode and modifiers are assigned together: two separate assignments published
        // twice, and the first publish carried the new key with the old modifiers.
        settings.undoHotkey = HotkeyBinding(keyCode: Int(kc), modifiers: meaningful.rawValue)
        stopRecording()
    }
}

// MARK: - Detection Tab

struct DetectionTab: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject private var l10n = Localization.shared

    var body: some View {
        Form {
            Section {
                Picker(L("detection.sensitivity"), selection: $settings.sensitivity) {
                    ForEach(SettingsModel.Sensitivity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(L("detection.sensitivityHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L("detection.section"))
            }

            Section {
                HStack {
                    Text(L("detection.delay"))
                    Spacer()
                    Text(L("detection.delayValue", settings.correctionDelayMs))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { Double(settings.correctionDelayMs) },
                        set: { settings.correctionDelayMs = Int($0) }
                    ),
                    in: 10...200,
                    step: 10
                )

                Text(L("detection.delayHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L("detection.timingSection"))
            }

            Section {
                Stepper(L("detection.minLength", settings.minWordLength),
                        value: $settings.minWordLength,
                        in: 2...5)

                Text(L("detection.minLengthHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L("detection.lengthSection"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Per-App Rules Tab

struct PerAppTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var showingAppPicker = false
    /// Refreshed when the tab appears and whenever an app launches or quits, so the popup
    /// never offers something that is no longer running.
    @State private var runningApps: [RunningApp] = []

    /// One entry in the "Add Running App" popup.
    struct RunningApp: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("perApp.hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(settings.appRules) { rule in
                    HStack {
                        if let icon = Self.icon(forBundleID: rule.bundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }

                        Text(rule.name)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { rule.isExcluded },
                            // Located by bundle ID rather than by a captured row index: an
                            // index goes stale the moment another row is removed, and the
                            // toggle would then flip a different app's rule.
                            set: { newValue in setExcluded(newValue, for: rule.bundleID) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()

                        Button {
                            remove(bundleID: rule.bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help(L("perApp.removeHelp", rule.name))
                    }
                }
                // Kept alongside the per-row button: this is what wires up the Delete key
                // and the Edit-mode affordance.
                .onDelete { indexSet in
                    settings.appRules.remove(atOffsets: indexSet)
                }
            }
            .listStyle(.bordered)

            HStack {
                // A popup rather than a button: the old "Add Running App..." added every
                // running app at once, so excluding one meant adding a dozen and deleting
                // the rest.
                Menu {
                    ForEach(addableRunningApps) { app in
                        Button {
                            add(app)
                        } label: {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                Text(app.name)
                            } else {
                                Text(app.name)
                            }
                        }
                    }
                } label: {
                    Text(L("perApp.addRunning"))
                }
                // Default (pull-down) style on purpose, so it sits next to the bordered
                // "Add App from Finder..." button as a matching control.
                .fixedSize()
                .disabled(addableRunningApps.isEmpty)
                .help(L(addableRunningApps.isEmpty
                        ? "perApp.addRunningEmpty"
                        : "perApp.addRunningHelp"))

                Button(L("perApp.addFromFinder")) {
                    showingAppPicker = true
                }

                Spacer()

                Button(L("perApp.removeAll")) {
                    settings.appRules.removeAll()
                }
                .disabled(settings.appRules.isEmpty)
            }
        }
        .padding()
        .onAppear { refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
                refreshRunningApps()
            }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                refreshRunningApps()
            }
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

    /// Running apps not already in the rules list.
    private var addableRunningApps: [RunningApp] {
        Self.addable(from: runningApps, existing: settings.appRules)
    }

    /// Only `.regular` apps — the ones with a Dock icon and windows you actually type in.
    /// Background agents and other menu-bar apps (this one included) are left out; "Add App
    /// from Finder..." is the escape hatch for anything unusual.
    private func refreshRunningApps() {
        runningApps = Self.normalize(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard let bundleID = app.bundleIdentifier,
                          let name = app.localizedName else { return nil }
                    return RunningApp(bundleID: bundleID, name: name, icon: menuIcon(app.icon))
                }
        )
    }

    /// Deduplicate by bundle ID and sort by display name.
    ///
    /// The dedup is load-bearing, not tidiness: one bundle ID can be running in several
    /// instances, and a repeated `Identifiable` id makes `ForEach` misbehave.
    static func normalize(_ apps: [RunningApp]) -> [RunningApp] {
        var seen = Set<String>()
        return apps
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The entries worth offering: everything running that is not already listed.
    static func addable(
        from running: [RunningApp],
        existing: [SettingsModel.AppRule]
    ) -> [RunningApp] {
        let known = Set(existing.map(\.bundleID))
        return running.filter { !known.contains($0.bundleID) }
    }

    /// A menu-sized copy of an app icon.
    ///
    /// Copied rather than resized in place: `NSRunningApplication.icon` hands back an image
    /// other parts of AppKit are also holding, and shrinking it would shrink it for them
    /// too. Menu items want ~16pt; the full-size 512pt icon renders as a giant thumbnail.
    private func menuIcon(_ image: NSImage?) -> NSImage? {
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func add(_ app: RunningApp) {
        guard !settings.appRules.contains(where: { $0.bundleID == app.bundleID }) else { return }
        settings.appRules.append(
            SettingsModel.AppRule(bundleID: app.bundleID, name: app.name, isExcluded: true)
        )
    }

    /// Drop a single app from the list. Once removed it reappears in the "Add Running App"
    /// popup, if it is still running.
    private func remove(bundleID: String) {
        settings.appRules.removeAll { $0.bundleID == bundleID }
    }

    private func setExcluded(_ excluded: Bool, for bundleID: String) {
        guard let index = settings.appRules.firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }
        settings.appRules[index].isExcluded = excluded
    }

    /// The Finder icon for an installed app, or nil when it cannot be located.
    ///
    /// `icon(forFile:)` never returns nil — handed an empty path it produces a generic
    /// document icon — so the lookup has to fail on the *path*, not on the icon.
    private static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
    @State private var importStatusMessage = ""

    /// One importer, told which side asked for it.
    ///
    /// There used to be two `.fileImporter` modifiers on this same view, one per language.
    /// SwiftUI keeps only one presentation of a given kind per view, so the second silently
    /// replaced the first and the English "Import Dictionary File..." button did nothing at
    /// all — the Ukrainian one worked purely because it happened to be declared last.
    @State private var showingFilePicker = false
    @State private var importLanguage: Language = .english

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // English column
                VStack(alignment: .leading) {
                    Text(L("dictionary.english"))
                        .font(.headline)

                    List {
                        ForEach(settings.customEnglishWords, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { indexSet in
                            settings.customEnglishWords.remove(atOffsets: indexSet)
                            rebuildDictionaries()
                        }
                    }
                    .listStyle(.bordered)

                    HStack {
                        TextField(L("dictionary.newWord"), text: $newEnglishWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addEnglishWord() }

                        Button("+") { addEnglishWord() }
                            .disabled(newEnglishWord.isEmpty)
                    }

                    Button(L("dictionary.import")) {
                        beginImport(for: .english)
                    }
                    .font(.caption)
                }

                // Ukrainian column
                VStack(alignment: .leading) {
                    Text(L("dictionary.ukrainian"))
                        .font(.headline)

                    List {
                        ForEach(settings.customUkrainianWords, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { indexSet in
                            settings.customUkrainianWords.remove(atOffsets: indexSet)
                            rebuildDictionaries()
                        }
                    }
                    .listStyle(.bordered)

                    HStack {
                        TextField(L("dictionary.newWord"), text: $newUkrainianWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addUkrainianWord() }

                        Button("+") { addUkrainianWord() }
                            .disabled(newUkrainianWord.isEmpty)
                    }

                    Button(L("dictionary.import")) {
                        beginImport(for: .ukrainian)
                    }
                    .font(.caption)
                }
            }

            // Imported dictionary files
            if !settings.customEnglishDictionaryPaths.isEmpty || !settings.customUkrainianDictionaryPaths.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("dictionary.importedFiles"))
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
                                rebuildDictionaries()
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
                                rebuildDictionaries()
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
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            // `importLanguage` is still the value set by whichever button opened the panel:
            // the completion runs before SwiftUI clears `showingFilePicker`, and nothing
            // else writes it.
            if case .success(let urls) = result, let url = urls.first {
                importDictionaryFile(url: url, language: importLanguage)
            }
        }
    }

    private func beginImport(for language: Language) {
        importLanguage = language
        showingFilePicker = true
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

        importStatusMessage = L("dictionary.importedCount", count, url.lastPathComponent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            importStatusMessage = ""
        }
    }

    private func addEnglishWord() {
        let word = newEnglishWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !settings.customEnglishWords.contains(word) else { return }
        settings.customEnglishWords.append(word)
        // Persisting alone is not enough: the detector consults DictionaryManager,
        // which reads these arrays only at launch. Push the word in live too.
        DictionaryManager.shared.addCustomEnglishWords([word])
        newEnglishWord = ""
    }

    private func addUkrainianWord() {
        let word = newUkrainianWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !settings.customUkrainianWords.contains(word) else { return }
        settings.customUkrainianWords.append(word)
        DictionaryManager.shared.addCustomUkrainianWords([word])
        newUkrainianWord = ""
    }

    /// Custom words merge into the same sets as the bundled lists, so removing one means
    /// rebuilding the sets from scratch. DictionaryManager serializes this with imports and
    /// additions; otherwise an older background rebuild can erase a newer user change.
    private func rebuildDictionaries() {
        let enWords = settings.customEnglishWords
        let uaWords = settings.customUkrainianWords
        let enPaths = settings.customEnglishDictionaryPaths
        let uaPaths = settings.customUkrainianDictionaryPaths
        DictionaryManager.shared.rebuildAsync(
            customEnglishWords: enWords,
            customUkrainianWords: uaWords,
            englishPaths: enPaths,
            ukrainianPaths: uaPaths
        )
    }
}

// MARK: - Statistics Tab

struct StatisticsTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Correction Statistics — in its own Form so it stays grouped.
            Form {
                Section {
                    HStack {
                        Text(L("stats.total"))
                        Spacer()
                        Text("\(settings.totalCorrections)")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text(L("stats.session"))
                        Spacer()
                        Text("\(settings.sessionCorrections)")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    Button(L("stats.reset")) {
                        settings.resetStatistics()
                    }
                    .foregroundColor(.red)
                } header: {
                    Text(L("stats.section"))
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 180)

            // Exceptions Editor — lives outside the Form so List(selection:) renders
            // as a proper interactive table with per-row controls.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("stats.exceptions", settings.exceptionWords.count))
                    .font(.headline)
                ExceptionsEditor(settings: settings)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

// MARK: - Exceptions Editor

/// List of self-learned exception words with per-row editing, per-row delete,
/// multi-select + bulk delete, and a "Clear All" action.
struct ExceptionsEditor: View {
    @ObservedObject var settings: SettingsModel
    @State private var selection = Set<String>()
    @State private var newWord: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.exceptionWords.isEmpty {
                Text(L("exceptions.empty"))
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                // Multi-select List. Each row has an inline TextField + delete button.
                List(selection: $selection) {
                    ForEach(settings.exceptionWords, id: \.self) { word in
                        ExceptionRow(
                            word: word,
                            onCommit: { newValue in commit(newValue, replacing: word) },
                            onDelete: { deleteWord(word) }
                        )
                        .tag(word)
                    }
                }
                .frame(minHeight: 140, maxHeight: 200)

                HStack {
                    Button(L("exceptions.deleteSelected")) { deleteSelected() }
                        .disabled(selection.isEmpty)

                    Text(L("exceptions.selectedCount", selection.count))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(L("exceptions.clearAll")) {
                        settings.exceptionWords.removeAll()
                        selection.removeAll()
                    }
                    .foregroundColor(.red)
                }
            }

            Divider()

            HStack {
                TextField(L("exceptions.addPlaceholder"), text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button(L("exceptions.add")) { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Write an edited word back to the list. Called once the user is done with the field,
    /// never while they are still typing in it.
    private func commit(_ newValue: String, replacing old: String) {
        let normalized = newValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized != old else { return }
        guard let index = settings.exceptionWords.firstIndex(of: old) else { return }

        // Empty text removes the word.
        if normalized.isEmpty {
            settings.exceptionWords.remove(at: index)
            selection.remove(old)
            return
        }
        // Deduplicate: if edited to a value already present elsewhere, drop this row.
        if settings.exceptionWords.contains(normalized) {
            settings.exceptionWords.remove(at: index)
            selection.remove(old)
            return
        }
        settings.exceptionWords[index] = normalized
        if selection.remove(old) != nil {
            selection.insert(normalized)
        }
    }

    private func deleteWord(_ word: String) {
        settings.exceptionWords.removeAll { $0 == word }
        selection.remove(word)
    }

    private func deleteSelected() {
        settings.exceptionWords.removeAll { selection.contains($0) }
        selection.removeAll()
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty, !settings.exceptionWords.contains(w) else {
            newWord = ""
            return
        }
        settings.exceptionWords.append(w)
        newWord = ""
    }
}

/// One editable exception word.
///
/// The text being typed lives here, in local state, and only reaches the model when the
/// field is done with. Editing used to write straight through on every keystroke, which
/// trimmed and lowercased the text as it was typed — so a capital or a space could not be
/// entered at all — and changed the row's identity with each character, tearing the
/// `TextField` down and taking the keyboard focus with it. It also wrote the whole list to
/// `UserDefaults` and rebuilt the lookup set per keystroke.
private struct ExceptionRow: View {
    let word: String
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onCommit(text) }

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help(L("exceptions.deleteHelp"))
        }
        // The row's identity is the word itself, so onAppear runs again whenever the model
        // value changes underneath.
        .onAppear { text = word }
        .onDisappear { onCommit(text) }
        .modifier(CommitOnFocusLoss(isFocused: isFocused) { onCommit(text) })
    }
}

/// Commits when focus leaves the field. Split out only to keep the availability dance for
/// `onChange` out of the row's body.
private struct CommitOnFocusLoss: ViewModifier {
    let isFocused: Bool
    let commit: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused && !nowFocused { commit() }
            }
        } else {
            content.onChange(of: isFocused) { nowFocused in
                if !nowFocused { commit() }
            }
        }
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
    @ObservedObject private var l10n = Localization.shared

    /// Read from the bundle rather than typed in, so it cannot disagree with the version
    /// the installer stamps into Info.plist.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Combined UK + Ukraine flag icon
            CombinedFlagIcon(size: 90)
                .padding(.top, 8)

            // Not localized: the product name is the same in every language.
            Text("MacKeySwitch")
                .font(.system(size: 22, weight: .bold))

            Text(L("about.tagline"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Text(L("about.version", version))
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Divider().frame(width: 250)

            // One description, in the chosen interface language. This used to print the
            // English and Ukrainian blocks one after the other, which was the only way to
            // reach both audiences before there was a language setting.
            VStack(spacing: 4) {
                Text(L("about.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text(L("about.detail"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 3) {
                Text(L("about.author"))
                    .font(.system(size: 11, weight: .medium))

                Text(L("about.licence"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}
