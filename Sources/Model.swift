import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ItemStatus: Equatable {
    case pending, converting, done, skipped(String), failed(String)
}

struct ConvItem: Identifiable {
    let id = UUID()
    let source: URL
    let relativeDir: String
    let originalSize: Int64
    var newSize: Int64?
    var output: URL?
    var status: ItemStatus = .pending
    var note: String?
    var originalTrashed = false

    var savedFraction: Double? {
        guard let newSize, originalSize > 0 else { return nil }
        return Double(originalSize - newSize) / Double(originalSize)
    }
}

@MainActor
final class ConverterModel: ObservableObject {
    static let shared = ConverterModel()

    @Published var items: [ConvItem] = []
    @Published var selection = Set<UUID>()
    /// Folders waiting for the user to pick import options; the folder sheet shows while this is non-empty.
    @Published var pendingFolders: [URL] = []
    @Published var isRunning = false
    @Published var doneCount = 0
    @Published var failedCount = 0
    @Published var skippedCount = 0
    @Published var trashedCount = 0
    @Published var bytesIn: Int64 = 0
    @Published var bytesOut: Int64 = 0
    @Published var cjxlPath = Tools.find("cjxl")
    @Published var exiftoolPath = Tools.find("exiftool")

    private let runner = Runner()

    var saved: Int64 { bytesIn - bytesOut }
    var savedFraction: Double { bytesIn > 0 ? Double(saved) / Double(bytesIn) : 0 }
    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var finishedCount: Int { doneCount + failedCount + skippedCount }
    var batchTotal = 0

    func refreshTools() {
        cjxlPath = Tools.find("cjxl")
        exiftoolPath = Tools.find("exiftool")
    }

    // MARK: Adding files

    /// Files are added straight away; folders open the folder options sheet first.
    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        var files: [FoundFile] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if !pendingFolders.contains(url) { pendingFolders.append(url) }
            } else {
                files.append(FoundFile(url: url, relativeDir: ""))
            }
        }
        addFound(files)
    }

    func addFound(_ found: [FoundFile]) {
        var known = Set(items.map { $0.source.standardizedFileURL.path })
        var added: [ConvItem] = []
        for f in found where Converter.isSupported(f.url) {
            let path = f.url.standardizedFileURL.path
            guard known.insert(path).inserted else { continue }
            added.append(ConvItem(source: f.url, relativeDir: f.relativeDir, originalSize: Converter.size(of: f.url)))
        }
        added.sort { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }
        items.append(contentsOf: added)
    }

    func remove(_ ids: Set<UUID>) {
        guard !isRunning else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        selection.removeAll()
        resetStats()
    }

    /// Puts finished/failed files back in the queue (e.g. to try different settings).
    func requeueAll() {
        guard !isRunning else { return }
        // Files whose originals went to the Trash can't be converted again.
        items.removeAll { $0.originalTrashed }
        selection.formIntersection(items.map(\.id))
        for i in items.indices {
            items[i].status = .pending
            items[i].newSize = nil
            items[i].output = nil
            items[i].note = nil
        }
        resetStats()
    }

    private func resetStats() {
        doneCount = 0; failedCount = 0; skippedCount = 0; trashedCount = 0; bytesIn = 0; bytesOut = 0; batchTotal = 0
    }

    // MARK: Converting

    /// With `deleteOriginals`, once the whole batch has finished (and wasn't stopped) the originals of
    /// successfully converted files are moved to the Trash. Skipped and failed files are left alone.
    func start(_ opts: ConvertOptions, deleteOriginals: Bool) {
        guard !isRunning, let cjxl = cjxlPath else { return }
        let jobs = items.filter { $0.status == .pending }.map { Job(id: $0.id, source: $0.source, relativeDir: $0.relativeDir) }
        guard !jobs.isEmpty else { return }

        isRunning = true
        batchTotal = finishedCount + jobs.count
        runner.reset()
        let runner = self.runner
        let exiftool = exiftoolPath
        let limit = max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 6))

        Task {
            await withTaskGroup(of: (UUID, Outcome).self) { group in
                var next = 0
                while next < min(limit, jobs.count) {
                    let job = jobs[next]; next += 1
                    setStatus(job.id, .converting)
                    group.addTask { (job.id, Converter.convert(job, opts: opts, cjxl: cjxl, exiftool: exiftool, runner: runner)) }
                }
                for await (id, outcome) in group {
                    apply(id, outcome)
                    if next < jobs.count, !runner.cancelled {
                        let job = jobs[next]; next += 1
                        setStatus(job.id, .converting)
                        group.addTask { (job.id, Converter.convert(job, opts: opts, cjxl: cjxl, exiftool: exiftool, runner: runner)) }
                    }
                }
            }
            if deleteOriginals && !runner.cancelled {
                trashOriginals(of: Set(jobs.map(\.id)))
            }
            isRunning = false
        }
    }

    private func trashOriginals(of ids: Set<UUID>) {
        for i in items.indices where ids.contains(items[i].id) && items[i].status == .done {
            // Only remove the original when its .jxl is really there.
            guard let output = items[i].output, Converter.size(of: output) > 0 else { continue }
            do {
                try FileManager.default.trashItem(at: items[i].source, resultingItemURL: nil)
                items[i].originalTrashed = true
                trashedCount += 1
            } catch {
                items[i].note = "Original couldn’t be moved to Trash"
            }
        }
    }

    func stop() { runner.cancelAll() }

    private func setStatus(_ id: UUID, _ status: ItemStatus) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }

    private func apply(_ id: UUID, _ outcome: Outcome) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case let .success(output, size, note):
            items[i].status = .done
            items[i].newSize = size
            items[i].output = output
            items[i].note = note
            withAnimation(.easeOut(duration: 0.6)) {
                bytesIn += items[i].originalSize
                bytesOut += size
                doneCount += 1
            }
        case let .skipped(msg):
            items[i].status = .skipped(msg)
            skippedCount += 1
        case let .failure(msg):
            if msg == "Cancelled" {
                items[i].status = .pending
                batchTotal -= 1
            } else {
                items[i].status = .failed(msg)
                failedCount += 1
            }
        }
    }

    // MARK: Panels

    func showAddPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Converter.supportedExts.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose images to convert to JPEG XL"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func showAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose folders of images to convert to JPEG XL"
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

enum Bytes {
    static func string(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
