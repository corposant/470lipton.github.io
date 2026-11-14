import Foundation

/// Where item files live: iCloud Drive when available, otherwise on the phone.
enum StorageLocation {
    static let lastFolderKey = "storageFolderPath"

    static var localFolder: URL {
        URL.documentsDirectory.appending(path: "Items", directoryHint: .isDirectory)
    }

    /// The folder used last time, so a cold launch from a notification button
    /// can load items instantly without waiting on iCloud.
    static func lastKnownFolder() -> URL {
        if let path = UserDefaults.standard.string(forKey: lastFolderKey) {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return localFolder
    }
}

/// All disk access, on one serial queue, coordinated with the iCloud daemon.
final class FileStorage: @unchecked Sendable {
    struct Snapshot {
        var items: [Item]
        /// IDs that exist in the folder, including ones still downloading.
        var presentIDs: Set<UUID>
        /// False when the folder itself couldn't be listed (iCloud mid-switch, a permissions hiccup).
        /// Then the snapshot says nothing about what exists, and must not be read as "everything was deleted".
        var folderReadable = true
        /// How many files actually had to be read (the rest hadn't changed).
        var filesRead = 0
    }

    /// What each file held when it was last read, keyed by path.
    struct FileCache {
        struct Stamp: Equatable {
            var modified: Date
            var size: Int
        }
        struct Entry {
            var stamp: Stamp
            var item: Item
        }
        var entries: [String: Entry] = [:]
    }

    private let queue = DispatchQueue(label: "io.nogapp.nog.files", qos: .userInitiated)
    /// Only touched on `queue`.
    private var cache = FileCache()

    /// Queue-owned failed operations retain their payload until retry or a newer
    /// mutation of the same path supersedes them. Never treat queue-drained as saved.
    private var failedOperations: [URL: () throws -> Void] = [:]
    private var failures: [URL: String] = [:]

    // MARK: Writes

    func write(_ text: String, to url: URL, completion: (@Sendable (Bool) -> Void)? = nil) {
        write(data: Data(text.utf8), to: url, completion: completion)
    }

    func write(data: Data, to url: URL, completion: (@Sendable (Bool) -> Void)? = nil) {
        enqueue(url, completion: completion) {
            try Self.coordinatedWrite(data, to: url)
        }
    }

    func delete(_ url: URL) {
        enqueue(url) {
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                } catch { operationError = error }
            }
            if let error = coordinationError ?? (operationError as NSError?) { throw error }
        }
    }

    /// The source is retained until the destination has been written and checked.
    /// This operation has no automatic retry: the owner must append metadata only
    /// after success, and may retry the whole attach transaction on failure.
    func move(_ source: URL, to destination: URL, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                let data = try Data(contentsOf: source)
                try Self.coordinatedWrite(data, to: destination)
                // Removing the temporary copy is best effort; it is safer to leave
                // an extra copy than report a successful recording as missing.
                try? FileManager.default.removeItem(at: source)
                completion(true)
            } catch { completion(false) }
        }
    }

    private func enqueue(_ url: URL, completion: (@Sendable (Bool) -> Void)? = nil,
                         operation: @escaping @Sendable () throws -> Void) {
        queue.async {
            // A later edit/delete supersedes an older failed operation at this path.
            self.failedOperations[url] = nil
            do {
                try operation()
                self.failures[url] = nil
                completion?(true)
            } catch {
                self.failedOperations[url] = operation
                self.failures[url] = error.localizedDescription
                completion?(false)
            }
        }
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        var completed = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
                // Read-back verifies the local write, not remote iCloud upload.
                guard try Data(contentsOf: target) == data else { throw CocoaError(.fileWriteUnknown) }
                completed = true
            } catch { operationError = error }
        }
        if let error = coordinationError ?? (operationError as NSError?) { throw error }
        guard completed else { throw CocoaError(.fileWriteUnknown) }
    }

    func failedPaths() async -> [String] {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.failures.keys.map(\.lastPathComponent).sorted()) }
        }
    }

    func retryFailed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                for (url, operation) in Array(self.failedOperations) {
                    do {
                        try operation()
                        self.failedOperations[url] = nil
                        self.failures[url] = nil
                    } catch { self.failures[url] = error.localizedDescription }
                }
                c.resume()
            }
        }
    }

    /// Includes sidecars and downloaded audio; keeps the source on any failure.
    func copySupportingFiles(from source: URL, to destination: URL) async -> Bool {
        await withCheckedContinuation { c in
            queue.async {
                do {
                    try Self.copySupportNow(from: source, to: destination)
                    c.resume(returning: true)
                } catch { c.resume(returning: false) }
            }
        }
    }

    static func isSidecar(_ name: String) -> Bool {
        name == "_places.json" || (name.hasPrefix("_nogmap") && name.hasSuffix(".json"))
    }

    private static func copySupportNow(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for url in urls where isSidecar(url.lastPathComponent) || url.pathExtension == VoiceNote.fileExtension {
            let target = destination.appending(path: url.lastPathComponent)
            let data = try readBytes(url)
            if fm.fileExists(atPath: target.path) {
                let existing = try readBytes(target)
                if existing == data { continue }
                // Switching storage carries the active source's sidecars. Keep
                // the other version for recovery before replacement.
                try archive(existing, named: target.lastPathComponent, beside: target)
                if url.pathExtension == VoiceNote.fileExtension {
                    // Same name with different audio: don't guess which is right.
                    try archive(data, named: url.lastPathComponent, beside: target)
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            try coordinatedWrite(data, to: target)
        }
    }

    private static func readBytes(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func archive(_ data: Data, named name: String, beside url: URL) throws {
        let folder = url.deletingLastPathComponent().appending(path: "_recovery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "\(UUID().uuidString)-\(name)"), options: .atomic)
    }

    /// Reads a whole file once queued writes have landed. With iCloud, waits for it to download.
    /// Runs off the write queue, so a slow download never holds up saving.
    func readData(at url: URL, coordinated: Bool) async -> Data? {
        await flush()
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                guard coordinated else { return c.resume(returning: try? Data(contentsOf: url)) }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                var result: Data?
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    readingItemAt: url, options: [], error: &coordinationError) { target in
                    result = try? Data(contentsOf: target)
                }
                c.resume(returning: result)
            }
        }
    }

    /// Waits until every queued write/delete has hit the disk.
    func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func flushSync() { queue.sync {} }

    // MARK: Reads

    /// Reads every item, re-reading only files that changed since the last read.
    func readAll(in folder: URL, coordinated: Bool) async -> Snapshot {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: Self.readAllNow(in: folder, coordinated: coordinated, cache: &self.cache)) }
        }
    }

    /// The same, waiting on the calling thread (launch, before the first frame).
    func readAllSync(in folder: URL, coordinated: Bool) -> Snapshot {
        queue.sync { Self.readAllNow(in: folder, coordinated: coordinated, cache: &cache) }
    }

    /// One-off read with nothing remembered (tests).
    static func readAllNow(in folder: URL, coordinated: Bool) -> Snapshot {
        var scratch = FileCache()
        return readAllNow(in: folder, coordinated: coordinated, cache: &scratch)
    }

    static func readAllNow(in folder: URL, coordinated: Bool, cache: inout FileCache) -> Snapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemHasUnresolvedConflictsKey,
                                         .contentModificationDateKey, .fileSizeKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        } catch {
            print("Nog: couldn't list \(folder.lastPathComponent): \(error)")
            return Snapshot(items: [], presentIDs: [], folderReadable: false)
        }
        var items: [Item] = []
        var present = Set<UUID>()
        var listed = Set<String>()
        var filesRead = 0

        for url in urls {
            let name = url.lastPathComponent
            // Not-yet-downloaded iCloud file: ".<id>.md.icloud"
            if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                if let id = UUID(uuidString: String(realName.dropLast(3))) { present.insert(id) }
                try? fm.startDownloadingUbiquitousItem(at: folder.appending(path: realName))
                continue
            }
            guard url.pathExtension == "md" else { continue }
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { present.insert(id) }

            let values = try? url.resourceValues(forKeys: keys)
            var hasConflicts = false
            if coordinated {
                if values?.isUbiquitousItem == true,
                   let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    if status == .notDownloaded { continue } // we'll reload when it arrives
                }
                hasConflicts = values?.ubiquitousItemHasUnresolvedConflicts == true
            }

            // Unchanged since we last read it (same modification date and size): reuse that.
            let path = url.path
            listed.insert(path)
            let stamp = values.flatMap { v in v.contentModificationDate.map { FileCache.Stamp(modified: $0, size: v.fileSize ?? -1) } }
            if !hasConflicts, let stamp, let cached = cache.entries[path], cached.stamp == stamp {
                present.insert(cached.item.id)
                items.append(cached.item)
                continue
            }

            if coordinated { resolveConflicts(at: url) }
            filesRead += 1
            guard let text = read(url, coordinated: coordinated), let item = ItemFile.decode(text) else {
                cache.entries[path] = nil
                continue
            }
            present.insert(item.id)
            items.append(item)
            // The stamp was taken before reading, so an edit landing mid-read just means one extra read next time.
            cache.entries[path] = hasConflicts ? nil : stamp.map { FileCache.Entry(stamp: $0, item: item) }
        }
        // Forget files that are gone (or belong to a folder we no longer use).
        cache.entries = cache.entries.filter { listed.contains($0.key) }
        return Snapshot(items: items, presentIDs: present, filesRead: filesRead)
    }

    private static func read(_ url: URL, coordinated: Bool) -> String? {
        guard coordinated else { return try? String(contentsOf: url, encoding: .utf8) }
        var result: String?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError) { target in
            result = try? String(contentsOf: target, encoding: .utf8)
        }
        return result
    }

    /// Archive every alternative before marking a conflict resolved. On any
    /// read/write/replacement error leave the versions unresolved and recoverable.
    private static func resolveConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        do {
            try archive(Data(contentsOf: url), named: url.lastPathComponent, beside: url)
            for version in conflicts {
                try archive(Data(contentsOf: version.url), named: url.lastPathComponent, beside: url)
            }
            let currentDate = NSFileVersion.currentVersionOfItem(at: url)?.modificationDate ?? .distantPast
            if let newest = conflicts.max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
               (newest.modificationDate ?? .distantPast) > currentDate {
                _ = try newest.replaceItem(at: url, options: [])
            }
            for version in conflicts { version.isResolved = true }
            // Keep archived versions; no unconditional removeOtherVersions call.
        } catch { print("Nog: conflict retained for recovery: \(error)") }
    }

    // MARK: iCloud

    /// Finds (and creates) iCloud Drive/Nog/Items, moving any on-phone items into it.
    /// Returns nil when iCloud is off, signed out, or the app isn't entitled to it.
    func resolveICloudFolder(migratingFrom local: URL) async -> URL? {
        await withCheckedContinuation { c in
            queue.async {
                guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                    c.resume(returning: nil)
                    return
                }
                let folder = container.appending(path: "Documents", directoryHint: .isDirectory)
                    .appending(path: "Items", directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Self.migrate(from: local, to: folder)
                    c.resume(returning: folder)
                } catch {
                    print("Nog: storage migration incomplete; originals retained: \(error)")
                    c.resume(returning: nil)
                }
            }
        }
    }

    /// Internal for failure-injection tests. Originals are removed only after
    /// successful comparison/archive/replacement; unavailable destinations abort.
    static func migrate(from local: URL, to cloud: URL) throws {
        let fm = FileManager.default
        guard local.standardizedFileURL != cloud.standardizedFileURL else { return }
        guard fm.fileExists(atPath: local.path) else { return }
        let urls = try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        for url in urls where url.pathExtension == "md" {
            let destination = cloud.appending(path: url.lastPathComponent)
            let localData = try Data(contentsOf: url)
            if fm.fileExists(atPath: destination.path) {
                let cloudData = try readBytes(destination)
                guard let localText = String(data: localData, encoding: .utf8),
                      let cloudText = String(data: cloudData, encoding: .utf8),
                      let localItem = ItemFile.decode(localText), let cloudItem = ItemFile.decode(cloudText)
                else { throw CocoaError(.fileReadCorruptFile) }
                if localData != cloudData {
                    // Preserve the losing content even when all writes succeed.
                    if localItem.updated > cloudItem.updated {
                        try archive(cloudData, named: url.lastPathComponent, beside: destination)
                        try coordinatedWrite(localData, to: destination)
                    } else {
                        try archive(localData, named: url.lastPathComponent, beside: destination)
                    }
                }
            } else {
                // Copy rather than move first: failure leaves the original intact.
                try coordinatedWrite(localData, to: destination)
            }
        }
        // Do not remove any input until every migration phase succeeds.
        // Sidecar alternatives are archived before replacement.
        try copySupportNow(from: local, to: cloud)
        for url in urls where isSidecar(url.lastPathComponent) || url.pathExtension == VoiceNote.fileExtension {
            let data = try Data(contentsOf: url)
            try archive(data, named: url.lastPathComponent, beside: cloud.appending(path: url.lastPathComponent))
        }
        for url in urls where url.pathExtension == "md" || isSidecar(url.lastPathComponent)
            || url.pathExtension == VoiceNote.fileExtension {
            try fm.removeItem(at: url)
        }
    }
}
