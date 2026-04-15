//
//  CacheManager.swift
//  QuickLookCodeShared
//
//  Manages a three-layer cache for the preview render pipeline:
//
//    L3 — App Group disk cache (survives process death).
//         Invalidated by: mtime mismatch on IDE app / settings.json, schema bump, Refresh.
//    L2 — Process-lifetime in-memory singletons (static vars on IDELocator/ThemeLoader/GrammarLoader).
//         Populated from L3 on first bootstrap(); survive across space-bar presses while
//         macOS keeps the QL extension host warm.
//    L1 — Per-render work: file read, tokenizeLine2 call, HTML build, WKWebView paint.
//         Only this runs on the hot path after the first preview.
//
//  Call bootstrap() once before the first render (idempotent). Call refresh() from the
//  host app's Refresh button to force a full rebuild.
//

import Foundation

public enum CacheManager {

    // MARK: - State

    private static var _bootstrapped = false
    private static let _lock = NSLock()

    // MARK: - Public API

    /// Ensures the cache is populated. Idempotent — a no-op after the first successful call.
    /// Blocks the calling thread while reading / rebuilding; should be called on a background
    /// thread (e.g. inside preparePreviewOfFile or at app launch before the first render).
    @discardableResult
    public static func bootstrap() -> Bool {
        _lock.lock()
        if _bootstrapped { _lock.unlock(); return true }
        _lock.unlock()

        let ok: Bool
        if cacheIsValid() {
            ok = loadFromDisk()
        } else {
            ok = rebuildAndLoad()
        }

        _lock.lock()
        _bootstrapped = ok
        _lock.unlock()
        return ok
    }

    /// Forces a full cache rebuild. Call from the host app's Refresh button.
    /// Clears L2 in-memory singletons and TokenizerEngine state so the next render
    /// uses the freshly built cache.
    public static func refresh() {
        _lock.lock()
        _bootstrapped = false
        _lock.unlock()

        // Drop L2 singletons.
        IDELocator._cached = nil
        ThemeLoader._cachedTheme = nil
        ThemeLoader._cachedSerializedTheme = nil
        GrammarLoader.invalidateStaticCaches()
        Task { await TokenizerEngine.shared.invalidate() }

        _ = rebuildAndLoad()

        _lock.lock()
        _bootstrapped = true
        _lock.unlock()
    }

    // MARK: - Cache directory

    /// Shared App Group container path for cache files.
    public static var cacheDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DiskCacheSchema.appGroup)?
            .appendingPathComponent("Library/Caches/\(DiskCacheSchema.dirName)", isDirectory: true)
    }

    /// Timestamp of the last successful cache build, or nil if no cache exists.
    public static var lastBuiltAt: Date? {
        guard let dir = cacheDir else { return nil }
        let url = dir.appendingPathComponent(DiskCacheSchema.manifestFile)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DiskCacheSchema.Manifest.self, from: data)
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: manifest.builtAt)
    }

    // MARK: - Validity check

    private static func cacheIsValid() -> Bool {
        guard let dir = cacheDir else { return false }
        let manifestURL = dir.appendingPathComponent(DiskCacheSchema.manifestFile)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(DiskCacheSchema.Manifest.self, from: data)
        else { return false }

        guard manifest.schemaVersion == DiskCacheSchema.schemaVersion else { return false }

        let fm = FileManager.default

        // IDE app must still exist at the same path with the same mtime.
        guard
            fm.fileExists(atPath: manifest.ideAppPath),
            let ideAttrs = try? fm.attributesOfItem(atPath: manifest.ideAppPath),
            let ideMtime = (ideAttrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate,
            abs(ideMtime - manifest.ideAppMtime) < 2.0
        else { return false }

        // settings.json mtime must match (detects theme-name change).
        let settingsPath = dir.appendingPathComponent(DiskCacheSchema.ideFile)
        if let ideData = try? Data(contentsOf: settingsPath),
           let cachedIDE = try? JSONDecoder().decode(DiskCacheSchema.CachedIDE.self, from: ideData),
           fm.fileExists(atPath: cachedIDE.settingsPath) {
            if let attrs = try? fm.attributesOfItem(atPath: cachedIDE.settingsPath),
               let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate,
               abs(mtime - manifest.settingsFileMtime) > 2.0 {
                return false
            }
        }

        return true
    }

    // MARK: - Load from disk

    @discardableResult
    private static func loadFromDisk() -> Bool {
        guard let dir = cacheDir else { return false }

        // IDE
        let ideURL = dir.appendingPathComponent(DiskCacheSchema.ideFile)
        if let data = try? Data(contentsOf: ideURL),
           let cached = try? JSONDecoder().decode(DiskCacheSchema.CachedIDE.self, from: data) {
            IDELocator._cached = cached.toIDEInfo()
        }

        // Theme
        let themeURL = dir.appendingPathComponent(DiskCacheSchema.themeFile)
        if let data = try? Data(contentsOf: themeURL),
           let cached = try? JSONDecoder().decode(DiskCacheSchema.CachedTheme.self, from: data) {
            ThemeLoader._cachedTheme = cached.themeData.toThemeData()
            ThemeLoader._cachedSerializedTheme = cached.serializedThemeJSON
        }

        // Grammar index
        let indexURL = dir.appendingPathComponent(DiskCacheSchema.grammarIndexFile)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode([String: String].self, from: data) {
            let urlIndex = Dictionary(
                uniqueKeysWithValues: index.map { ($0.key, URL(fileURLWithPath: $0.value)) }
            )
            GrammarLoader.seedURLIndex(urlIndex)
        }

        return IDELocator._cached != nil && ThemeLoader._cachedTheme != nil
    }

    // MARK: - Rebuild

    @discardableResult
    private static func rebuildAndLoad() -> Bool {
        guard let dir = cacheDir else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Detect IDE.
        guard let ide = IDELocator.installedIDEs().first else {
            NSLog("[QuickLookCode] CacheManager: no IDE found, cache not built")
            return false
        }

        // 2. Load theme from disk.
        guard let theme = try? ThemeLoader.loadActiveThemeFromDisk(from: ide) else {
            NSLog("[QuickLookCode] CacheManager: could not load theme, cache not built")
            return false
        }
        guard let serializedTheme = try? SourceCodeRenderer.serializeTheme(theme) else {
            NSLog("[QuickLookCode] CacheManager: could not serialize theme")
            return false
        }

        // 3. Build grammar index (one-time directory walk for all known languages).
        let grammarIndex = buildGrammarIndex(ide: ide)

        // 4. Determine mtimes for manifest.
        let ideAppMtime    = mtime(of: ide.appURL.path)
        let settingsMtime  = mtime(of: ide.settingsURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Write ide.json
        let cachedIDE = DiskCacheSchema.CachedIDE(
            name: ide.name,
            appPath: ide.appURL.path,
            userExtensionsPath: ide.userExtensionsURL.path,
            settingsPath: ide.settingsURL.path
        )
        if let data = try? encoder.encode(cachedIDE) {
            try? data.write(to: dir.appendingPathComponent(DiskCacheSchema.ideFile), options: .atomic)
        }

        // Write theme.json
        let tokenColorRecords = theme.tokenColors.map {
            DiskCacheSchema.TokenColorRecord(
                scopes: $0.scopes,
                foreground: $0.foreground,
                fontStyle: $0.fontStyle
            )
        }
        let themeRecord = DiskCacheSchema.ThemeRecord(
            name: theme.name,
            isDark: theme.isDark,
            background: theme.background,
            foreground: theme.foreground,
            tokenColors: tokenColorRecords
        )
        let cachedTheme = DiskCacheSchema.CachedTheme(
            themeData: themeRecord,
            serializedThemeJSON: serializedTheme
        )
        if let data = try? encoder.encode(cachedTheme) {
            try? data.write(to: dir.appendingPathComponent(DiskCacheSchema.themeFile), options: .atomic)
        }

        // Write grammar-index.json
        let indexStrings = grammarIndex.mapValues { $0.path }
        if let data = try? encoder.encode(indexStrings) {
            try? data.write(
                to: dir.appendingPathComponent(DiskCacheSchema.grammarIndexFile),
                options: .atomic
            )
        }

        // Write manifest.json last — its presence signals a complete cache.
        let manifest = DiskCacheSchema.Manifest(
            schemaVersion: DiskCacheSchema.schemaVersion,
            cacheVersion: UUID().uuidString,
            builtAt: Date().timeIntervalSinceReferenceDate,
            ideAppPath: ide.appURL.path,
            ideAppMtime: ideAppMtime,
            settingsFileMtime: settingsMtime
        )
        if let data = try? encoder.encode(manifest) {
            try? data.write(
                to: dir.appendingPathComponent(DiskCacheSchema.manifestFile),
                options: .atomic
            )
        }

        // 5. Populate L2 in-memory singletons.
        IDELocator._cached = ide
        ThemeLoader._cachedTheme = theme
        ThemeLoader._cachedSerializedTheme = serializedTheme
        GrammarLoader.seedURLIndex(grammarIndex)

        NSLog("[QuickLookCode] CacheManager: cache rebuilt for %@ (%d grammar entries)",
              ide.name, grammarIndex.count)
        return true
    }

    // MARK: - Grammar index

    private static func buildGrammarIndex(ide: IDEInfo) -> [String: URL] {
        let loader = GrammarLoader(ide: ide)
        var index: [String: URL] = [:]
        for term in FileTypeRegistry.allGrammarSearchTerms {
            if let url = loader.grammarURL(for: term) {
                index[term] = url
            }
        }
        return index
    }

    // MARK: - Helpers

    private static func mtime(of path: String) -> Double {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let date  = attrs[.modificationDate] as? Date
        else { return 0 }
        return date.timeIntervalSinceReferenceDate
    }
}
