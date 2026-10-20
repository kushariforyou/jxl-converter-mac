import SwiftUI
import AppKit

@main
struct JXLConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = ConverterModel.shared

    var body: some Scene {
        Window("JXL Converter", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { model.showAddPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.isRunning)
                Button("Add Folder…") { model.showAddFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isRunning)
            }
            // Replace Cut/Copy/Paste/Delete with the actions this app actually has.
            CommandGroup(replacing: .pasteboard) {
                Button("Remove from List") { model.remove(model.selection) }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.isRunning || model.selection.isEmpty)
                Button("Select All") { model.selection = Set(model.items.map(\.id)) }
                    .keyboardShortcut("a")
                    .disabled(model.items.isEmpty)
            }
            CommandGroup(replacing: .help) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Images or folders dropped on the Dock icon (or opened with the app) join the list.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ConverterModel.shared.add(urls) }
    }

    // SwiftUI always adds a Help menu (with a search field) even when its items are removed,
    // so take it out of the menu bar whenever SwiftUI rebuilds the menus.
    func applicationDidFinishLaunching(_ notification: Notification) {
        removeHelpMenu()
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.removeHelpMenu() }
        }
    }

    @MainActor private func removeHelpMenu() {
        guard let menu = NSApp.mainMenu else { return }
        let help = NSApp.helpMenu
        for item in menu.items where item.submenu === help || item.title == "Help" {
            menu.removeItem(item)
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var model: ConverterModel

    @AppStorage("lossless") private var lossless = true
    @AppStorage("quality") private var quality = 90.0
    @AppStorage("effort") private var effort = 7
    @AppStorage("keepMetadata") private var keepMetadata = true
    @AppStorage("overwrite") private var overwrite = false
    @AppStorage("skipLarger") private var skipLarger = true
    @AppStorage("outputPath") private var outputPath = ""

    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.cjxlPath == nil { missingToolBanner }
                fileArea
            }
            Divider()
            sidebar
                .frame(width: 300)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.showAddPanel() } label: { Label("Add Images", systemImage: "plus") }
                    .help("Add images (⌘O)")
                    .disabled(model.isRunning)
                Button { model.showAddFolderPanel() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    .help("Add a folder of images (⇧⌘O)")
                    .disabled(model.isRunning)
                Button { model.requeueAll() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .help("Put all files back in the queue to convert again")
                    .disabled(model.isRunning || model.items.isEmpty)
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Remove all files from the list")
                    .disabled(model.isRunning || model.items.isEmpty)
            }
        }
        .navigationSubtitle(model.items.isEmpty ? "" : "\(model.items.count) images")
        .sheet(isPresented: Binding(get: { !model.pendingFolders.isEmpty },
                                    set: { if !$0 { model.pendingFolders = [] } })) {
            FolderImportSheet()
        }
    }

    // MARK: File list

    private var fileArea: some View {
        ZStack {
            if model.items.isEmpty {
                emptyState
            } else {
                fileTable
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isRunning else { return false }
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop images or folders here")
                .font(.title2.weight(.medium))
            Text("JPEG, PNG, GIF, HEIC, TIFF, WebP, AVIF, BMP, RAW and more")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Choose Images…") { model.showAddPanel() }
                Button("Choose Folder…") { model.showAddFolderPanel() }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTable: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn("File") { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.source.path))
                        .resizable().frame(width: 16, height: 16)
                    Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .help(item.source.path)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Original") { item in
                Text(Bytes.string(item.originalSize)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
            TableColumn("JPEG XL") { item in
                Text(item.newSize.map(Bytes.string) ?? "—").monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Saved") { item in
                if let f = item.savedFraction {
                    Text(f >= 0 ? "−\(Int((f * 100).rounded()))%" : "+\(Int((-f * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(f >= 0 ? .green : .orange)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 55, ideal: 60)
            TableColumn("Status") { item in
                StatusView(item: item)
            }
            .width(min: 90, ideal: 140)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let picked = model.items.filter { ids.contains($0.id) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(picked.map { $0.output ?? $0.source })
            }
            Button("Remove from List") { model.remove(ids) }
                .disabled(model.isRunning)
        } primaryAction: { ids in
            let urls = model.items.filter { ids.contains($0.id) }.map { $0.output ?? $0.source }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private var missingToolBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("The JPEG XL encoder (cjxl) wasn't found.").fontWeight(.medium)
                Text("Install it with Homebrew:  brew install jpeg-xl exiftool")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install jpeg-xl exiftool", forType: .string)
            }
            Button("Check Again") { model.refreshTools() }
        }
        .padding(12)
        .background(.yellow.opacity(0.12))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            statsCard.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    compressionSection
                    metadataSection
                    outputSection
                }
                .padding(16)
            }
            Divider()
            convertButton.padding(16)
        }
        .background(.background.secondary)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.saved < 0 ? "Size increase" : "Space saved")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            CountingBytes(value: Double(model.saved))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(model.saved < 0 ? Color.orange : Color.green)
            HStack(spacing: 4) {
                CountingPercent(value: abs(model.savedFraction) * 100)
                Text(model.saved < 0 ? "larger" : "smaller")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .opacity(model.bytesIn > 0 ? 1 : 0)

            if model.bytesIn > 0 {
                Text("\(Bytes.string(model.bytesIn)) → \(Bytes.string(model.bytesOut))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }

            if model.batchTotal > 0 {
                ProgressView(value: Double(model.finishedCount), total: Double(max(model.batchTotal, 1)))
                    .padding(.top, 4)
                HStack {
                    Text("\(model.finishedCount) of \(model.batchTotal) done")
                    Spacer()
                    if model.skippedCount > 0 {
                        Text("\(model.skippedCount) kept").foregroundStyle(.secondary)
                    }
                    if model.failedCount > 0 {
                        Text("\(model.failedCount) failed").foregroundStyle(.red)
                    }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Compression")
            Toggle("Lossless", isOn: $lossless)
            Text(lossless
                 ? "Pixel-perfect. JPEGs are repacked losslessly (≈20% smaller) and can be restored bit-for-bit."
                 : "Lossy. Smaller files; 90 is visually lossless.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text("\(Int(quality))").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $quality, in: 50...99, step: 1)
            }
            .disabled(lossless)
            .opacity(lossless ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Effort")
                    Spacer()
                    Text("\(effort)").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(effort) }, set: { effort = Int($0) }), in: 1...9, step: 1)
                Text("Higher is smaller but slower. 7 is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Metadata")
            Toggle("Preserve EXIF & XMP metadata", isOn: $keepMetadata)
            Text(keepMetadata
                 ? "Keeps camera info, GPS, dates and file timestamps."
                 : "Strips EXIF, XMP and JUMBF. Color profile is kept.")
                .font(.caption).foregroundStyle(.secondary)
            if keepMetadata, model.exiftoolPath == nil {
                Label("exiftool not found — metadata from HEIC/TIFF/RAW won't be copied.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Output")
            Picker("", selection: Binding(
                get: { outputPath.isEmpty ? 0 : 1 },
                set: { if $0 == 0 { outputPath = "" } else { chooseOutputFolder() } }
            )) {
                Text("Next to originals").tag(0)
                Text("Custom folder…").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !outputPath.isEmpty {
                HStack {
                    Image(systemName: "folder")
                    Text((outputPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseOutputFolder() }.controlSize(.small)
                }
                .font(.caption)
                .help(outputPath)
            }
            Toggle("Keep original if JPEG XL is larger", isOn: $skipLarger)
            Text("Already-compressed formats like HEIC often grow; those .jxl files are discarded.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Overwrite existing .jxl files", isOn: $overwrite)
            Text("Original files are never modified.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var convertButton: some View {
        Group {
            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    model.start(ConvertOptions(
                        lossless: lossless,
                        quality: Int(quality),
                        effort: effort,
                        keepMetadata: keepMetadata,
                        outputDir: outputPath.isEmpty ? nil : URL(fileURLWithPath: outputPath, isDirectory: true),
                        overwrite: overwrite,
                        skipLarger: skipLarger))
                } label: {
                    Label(model.pendingCount > 0 ? "Convert \(model.pendingCount) to JPEG XL" : "Convert to JPEG XL",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingCount == 0 || model.cjxlPath == nil)
            }
        }
        .controlSize(.large)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputPath = url.path }
    }
}

// MARK: - Folder options

/// Asks whether to include subfolders and which file types to pick up before adding a folder.
struct FolderImportSheet: View {
    @EnvironmentObject var model: ConverterModel
    @AppStorage("folderRecursive") private var recursive = true
    @AppStorage("folderExcludedKinds") private var excludedRaw = ""
    @State private var found: [FoundFile]?

    private var excluded: Set<FileKind> {
        Set(excludedRaw.split(separator: ",").compactMap { FileKind(rawValue: String($0)) })
    }
    private var extensions: Set<String> {
        FileKind.allCases.filter { !excluded.contains($0) }.reduce(into: Set()) { $0.formUnion($1.extensions) }
    }
    private var scanKey: String { "\(recursive)|\(excludedRaw)|\(model.pendingFolders.map(\.path))" }

    private func setExcluded(_ kinds: Set<FileKind>) {
        excludedRaw = kinds.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func binding(_ kind: FileKind) -> Binding<Bool> {
        Binding(get: { !excluded.contains(kind) },
                set: { on in
                    var ex = excluded
                    if on { ex.remove(kind) } else { ex.insert(kind) }
                    setExcluded(ex)
                })
    }

    var body: some View {
        let folders = model.pendingFolders
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folders.count == 1 ? "Add “\(folders[0].lastPathComponent)”" : "Add \(folders.count) folders")
                        .font(.headline)
                    Text(folders.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Include subfolders", isOn: $recursive)
                Text(recursive
                     ? "Adds images from every folder inside, too."
                     : "Only adds images directly inside the folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("File types").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("All") { setExcluded([]) }.buttonStyle(.link)
                    Button("None") { setExcluded(Set(FileKind.allCases)) }.buttonStyle(.link)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(FileKind.allCases) { kind in
                        Toggle(kind.title, isOn: binding(kind)).help(kind.detail)
                    }
                }
            }

            Divider()

            HStack {
                if let found {
                    Text(found.isEmpty ? "No matching images" : "\(found.count) image\(found.count == 1 ? "" : "s") found")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.pendingFolders = [] }
                    .keyboardShortcut(.cancelAction)
                Button(found.map { $0.isEmpty ? "Add" : "Add \($0.count) Image\($0.count == 1 ? "" : "s")" } ?? "Add") {
                    model.addFound(found ?? [])
                    model.pendingFolders = []
                }
                .keyboardShortcut(.defaultAction)
                .disabled(found?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: scanKey) {
            found = nil
            let folders = model.pendingFolders, recursive = recursive, exts = extensions
            let result = await Task.detached {
                folders.flatMap { Converter.scanFolder($0, recursive: recursive, extensions: exts) }
            }.value
            if !Task.isCancelled { found = result }
        }
    }
}

// MARK: - Small views

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct StatusView: View {
    let item: ConvItem
    var body: some View {
        switch item.status {
        case .pending:
            Text("Waiting").foregroundStyle(.secondary)
        case .converting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Converting")
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: item.note == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(item.note == nil ? .green : .orange)
                Text(item.note ?? "Done")
            }
            .help(item.output?.path ?? "")
        case .skipped(let msg):
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
                Text(msg).lineLimit(1).foregroundStyle(.secondary)
            }
            .help(msg)
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(msg).lineLimit(1)
            }
            .help(msg)
        }
    }
}

/// Animates through intermediate values so the number visibly counts up.
struct CountingBytes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text((value < 0 ? "+" : "") + Bytes.string(Int64(abs(value))))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

struct CountingPercent: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(String(format: "%.1f%%", value)).monospacedDigit()
    }
}
