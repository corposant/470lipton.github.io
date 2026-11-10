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
    }

    private let queue = DispatchQueue(label: "io.nogapp.nog.files", qos: .userInitiated)

    // MARK: Writes

    func write(_ text: String, to url: URL) {
        write(data: Data(text.utf8), to: url)
    }

    func write(data: Data, to url: URL) {
        queue.async {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try data.write(to: target, options: .atomic) } catch { print("Nog: write failed \(target.lastPathComponent): \(error)") }
            }
            if let coordinationError { print("Nog: write coordination failed: \(coordinationError)") }
        }
    }

    func delete(_ url: URL) {
        queue.async {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
    }

    /// Waits until every queued write/delete has hit the disk.
    func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func flushSync() { queue.sync {} }

    // MARK: Reads

    func readAll(in folder: URL, coordinated: Bool) async -> Snapshot {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: Self.readAllNow(in: folder, coordinated: coordinated)) }
        }
    }

    static func readAllNow(in folder: URL, coordinated: Bool) -> Snapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        } catch {
            print("Nog: couldn't list \(folder.lastPathComponent): \(error)")
            return Snapshot(items: [], presentIDs: [], folderReadable: false)
        }
        var items: [Item] = []
        var present = Set<UUID>()

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

            if coordinated {
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isUbiquitousItem == true,
                   let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    if status == .notDownloaded { continue } // we'll reload when it arrives
                }
                resolveConflicts(at: url)
            }
            guard let text = read(url, coordinated: coordinated), let item = ItemFile.decode(text) else { continue }
            present.insert(item.id)
            items.append(item)
        }
        return Snapshot(items: items, presentIDs: present)
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

    /// If two devices edited the same item while offline, keep the most recent edit.
    private static func resolveConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        let currentDate = NSFileVersion.currentVersionOfItem(at: url)?.modificationDate ?? .distantPast
        if let newest = conflicts.max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
           (newest.modificationDate ?? .distantPast) > currentDate {
            _ = try? newest.replaceItem(at: url, options: [])
        }
        for version in conflicts { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
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
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                Self.migrate(from: local, to: folder)
                c.resume(returning: folder)
            }
        }
    }

    private static func migrate(from local: URL, to cloud: URL) {
        let fm = FileManager.default
        guard local.standardizedFileURL != cloud.standardizedFileURL,
              let urls = try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "md" {
            let destination = cloud.appending(path: url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                // Both exist (e.g. you switched to on-phone storage and back): keep the newer edit.
                let localItem = read(url, coordinated: false).flatMap(ItemFile.decode)
                let cloudItem = read(destination, coordinated: true).flatMap(ItemFile.decode)
                if let localItem, (cloudItem?.updated ?? .distantPast) < localItem.updated,
                   let data = try? Data(contentsOf: url) {
                    var coordinationError: NSError?
                    NSFileCoordinator(filePresenter: nil).coordinate(
                        writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                        try? data.write(to: target, options: .atomic)
                    }
                }
                try? fm.removeItem(at: url)
            } else {
                do { try fm.setUbiquitous(true, itemAt: url, destinationURL: destination) }
                catch { print("Nog: couldn't move \(url.lastPathComponent) to iCloud: \(error)") }
            }
        }
    }
}
