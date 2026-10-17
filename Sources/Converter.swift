import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ConvertOptions: Sendable {
    var lossless: Bool
    var quality: Int
    var effort: Int
    var keepMetadata: Bool
    var outputDir: URL?
    var overwrite: Bool
    var skipLarger: Bool
}

struct Job: Sendable {
    let id: UUID
    let source: URL
    let relativeDir: String
}

enum Outcome: Sendable {
    case success(output: URL, size: Int64, note: String?)
    case skipped(String)
    case failure(String)
}

// MARK: - External tools

enum Tools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static func find(_ name: String) -> String? {
        var dirs = searchDirs
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            dirs.insert(bundled, at: 0)
        }
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs command-line tools and lets the UI cancel everything in flight.
final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var procs = Set<Process>()
    private var _cancelled = false

    var cancelled: Bool { lock.withLock { _cancelled } }
    func reset() { lock.withLock { _cancelled = false } }
    func cancelAll() {
        lock.withLock {
            _cancelled = true
            procs.forEach { $0.terminate() }
        }
    }

    func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Tools.searchDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        lock.withLock { _ = procs.insert(p) }
        if cancelled { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.withLock { _ = procs.remove(p) }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Conversion

enum Converter {
    /// Formats cjxl reads natively (metadata carried over by cjxl itself).
    static let directExts: Set<String> = ["jpg", "jpeg", "jpe", "png", "apng", "gif", "ppm", "pnm", "pgm", "pbm", "pam", "pfm", "exr"]
    /// Formats decoded through ImageIO first (metadata copied with exiftool).
    static let imageIOExts: Set<String> = ["heic", "heif", "hif", "tif", "tiff", "bmp", "webp", "avif", "dng", "cr2", "cr3",
                                           "nef", "arw", "raf", "orf", "rw2", "psd", "tga", "jp2", "ico"]
    static let supportedExts = directExts.union(imageIOExts)

    static func isSupported(_ url: URL) -> Bool {
        supportedExts.contains(url.pathExtension.lowercased())
    }

    static func convert(_ job: Job, opts: ConvertOptions, cjxl: String, exiftool: String?, runner: Runner) -> Outcome {
        let fm = FileManager.default
        let src = job.source
        let ext = src.pathExtension.lowercased()
        let isJPEG = ["jpg", "jpeg", "jpe"].contains(ext)
        let direct = directExts.contains(ext)

        let destDir = opts.outputDir.map { $0.appendingPathComponent(job.relativeDir, isDirectory: true) }
            ?? src.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            return .failure("Can't create folder: \(error.localizedDescription)")
        }
        let out = reserveOutput(for: src, in: destDir, overwrite: opts.overwrite)

        // Formats cjxl can't read are decoded to a temporary 16-bit-capable PNG first.
        var input = src
        var tempPNG: URL?
        var bakedOrientation = false
        defer { if let tempPNG { try? fm.removeItem(at: tempPNG) } }
        if !direct {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            guard let rotated = decodeToPNG(src, dest: tmp) else {
                try? fm.removeItem(at: out)
                return .failure("Couldn't decode image")
            }
            tempPNG = tmp
            input = tmp
            bakedOrientation = rotated
        }

        var args = [input.path, out.path, "-e", "\(opts.effort)", "--quiet"]
        if opts.lossless {
            args += ["-d", "0"]
            if isJPEG { args += ["--lossless_jpeg=1"] }
        } else {
            args += ["-q", "\(opts.quality)"]
            if isJPEG { args += ["--lossless_jpeg=0"] }
        }
        if !opts.keepMetadata {
            args += ["-x", "strip=exif", "-x", "strip=xmp", "-x", "strip=jumbf"]
            if isJPEG && opts.lossless { args += ["--allow_jpeg_reconstruction=0"] }
        }

        let result = runner.run(cjxl, args)
        guard result.status == 0, size(of: out) > 0 else {
            try? fm.removeItem(at: out)
            if runner.cancelled { return .failure("Cancelled") }
            let msg = result.output.split(separator: "\n").last.map(String.init) ?? "cjxl failed (\(result.status))"
            return .failure(msg)
        }

        var note: String?
        if opts.keepMetadata {
            // cjxl keeps EXIF/XMP itself for JPEG→lossless and PNG; lossy JPEG drops XMP, ImageIO formats lose all.
            if !direct || (isJPEG && !opts.lossless) {
                if let exiftool {
                    var exArgs = ["-q", "-q", "-m", "-overwrite_original", "-tagsFromFile", src.path, "-all:all"]
                    if bakedOrientation { exArgs.append("-EXIF:Orientation#=1") }
                    exArgs.append(out.path)
                    let r = runner.run(exiftool, exArgs)
                    if r.status != 0 { note = "Metadata not copied" }
                } else {
                    note = "exiftool missing – metadata not copied"
                }
            }
            copyDates(from: src, to: out)
        }
        let newSize = size(of: out)
        if opts.skipLarger, newSize >= size(of: src) {
            try? fm.removeItem(at: out)
            return .skipped("Kept original – JXL was larger")
        }
        return .success(output: out, size: newSize, note: note)
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Picks `name.jxl` (or `name (n).jxl`) and atomically claims it so parallel jobs never collide.
    private static func reserveOutput(for src: URL, in dir: URL, overwrite: Bool) -> URL {
        let base = src.deletingPathExtension().lastPathComponent
        let first = dir.appendingPathComponent(base + ".jxl")
        if overwrite { return first }
        var url = first
        var n = 1
        while true {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return url }
            url = dir.appendingPathComponent("\(base) (\(n)).jxl")
            n += 1
        }
    }

    /// Decodes with ImageIO and writes a PNG. Returns whether EXIF orientation was baked into the pixels,
    /// or nil on failure.
    private static func decodeToPNG(_ src: URL, dest: URL) -> Bool? {
        guard let isrc = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(isrc) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(isrc, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(isrc, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image,
              let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? (orientation != 1) : nil
    }

    private static func copyDates(from src: URL, to dst: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        try? FileManager.default.setAttributes(keep, ofItemAtPath: dst.path)
    }
}
