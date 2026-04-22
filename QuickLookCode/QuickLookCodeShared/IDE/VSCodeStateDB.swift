//
//  VSCodeStateDB.swift
//  QuickLookCodeShared
//
//  Read-only access to VS Code / Antigravity's Electron state database
//  (`state.vscdb`). Used as the fallback source for the active theme name
//  when `settings.json` has no `workbench.colorTheme` entry — VS Code caches
//  the fully-resolved active theme here so it can render immediately on
//  startup before extensions load.
//
//  We never open the DB read-write; `SQLITE_OPEN_READONLY` also avoids
//  creating the `-wal` / `-shm` sidecar files the writer would, so running
//  this while VS Code itself is open is safe.
//

import Foundation
import SQLite3

enum VSCodeStateDB {

    /// Reads the `settingsId` field from the `colorThemeData` row of the
    /// `ItemTable` — i.e. the theme name that would otherwise live in
    /// `settings.json` under `workbench.colorTheme`. Returns nil when the
    /// DB isn't present, the row is missing, or the value isn't valid JSON.
    static func activeThemeName(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key='colorThemeData' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let json = String(cString: cStr)

        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let settingsId = obj["settingsId"] as? String,
            !settingsId.isEmpty
        else { return nil }

        return settingsId
    }
}
