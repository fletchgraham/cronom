import Foundation
import SQLite3

struct TaskItem: Identifiable, Hashable {
    let id: Int64
    var name: String
    var done: Bool
    var todaySeconds: Double
    var totalSeconds: Double
}

enum DatabaseError: Error {
    case open(String)
    case exec(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite wrapper. Times are stored as unix seconds (REAL).
///
/// Schema:
///   tasks(id, name, done, created_at, position)
///   segments(id, task_id, start, end, manual) — one row per stretch of focused time on a task.
///     Manual rows are time corrections; their end - start may be negative.
final class Database {
    private var db: OpaquePointer?

    static func openDefault() throws -> Database {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cronom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Database(path: dir.appendingPathComponent("cronom.sqlite").path)
    }

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS segments (
                id INTEGER PRIMARY KEY,
                task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                start REAL NOT NULL,
                end REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS segments_task ON segments(task_id);
            CREATE INDEX IF NOT EXISTS segments_start ON segments(start);
            """)
        try migrate()
    }

    private func migrate() throws {
        var version: Int32 = 0
        query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        if version < 1 {
            try exec("""
                BEGIN;
                ALTER TABLE tasks ADD COLUMN position REAL NOT NULL DEFAULT 0;
                UPDATE tasks SET position = id;
                ALTER TABLE segments ADD COLUMN manual INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version = 1;
                COMMIT;
                """)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Tasks

    @discardableResult
    func addTask(name: String) -> Int64 {
        run("""
            INSERT INTO tasks (name, created_at, position)
            VALUES (?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM tasks))
            """, .text(name), .real(Date().timeIntervalSince1970))
        return sqlite3_last_insert_rowid(db)
    }

    /// Rewrite positions so tasks sort in the given order.
    func reorder(_ ids: [Int64]) {
        try? exec("BEGIN")
        for (i, id) in ids.enumerated() {
            run("UPDATE tasks SET position = ? WHERE id = ?", .real(Double(i)), .int(id))
        }
        try? exec("COMMIT")
    }

    func setDone(_ id: Int64, _ done: Bool) {
        run("UPDATE tasks SET done = ? WHERE id = ?", .int(done ? 1 : 0), .int(id))
    }

    func rename(_ id: Int64, to name: String) {
        run("UPDATE tasks SET name = ? WHERE id = ?", .text(name), .int(id))
    }

    func deleteTask(_ id: Int64) {
        run("DELETE FROM tasks WHERE id = ?", .int(id))
    }

    /// All tasks with time attributed today (since `dayStart`) and all-time.
    func tasks(dayStart: Date) -> [TaskItem] {
        let sql = """
            SELECT t.id, t.name, t.done,
                   COALESCE(SUM(CASE WHEN s.start >= ?1 THEN s.end - s.start ELSE 0 END), 0),
                   COALESCE(SUM(s.end - s.start), 0)
            FROM tasks t LEFT JOIN segments s ON s.task_id = t.id
            GROUP BY t.id
            ORDER BY t.done, t.position, t.id
            """
        var items: [TaskItem] = []
        query(sql, .real(dayStart.timeIntervalSince1970)) { stmt in
            items.append(TaskItem(
                id: sqlite3_column_int64(stmt, 0),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                done: sqlite3_column_int(stmt, 2) != 0,
                todaySeconds: sqlite3_column_double(stmt, 3),
                totalSeconds: sqlite3_column_double(stmt, 4)
            ))
        }
        return items
    }

    // MARK: Segments

    func startSegment(taskID: Int64, at date: Date) -> Int64 {
        let t = date.timeIntervalSince1970
        run("INSERT INTO segments (task_id, start, end) VALUES (?, ?, ?)", .int(taskID), .real(t), .real(t))
        return sqlite3_last_insert_rowid(db)
    }

    func updateSegment(_ id: Int64, end date: Date) {
        run("UPDATE segments SET end = ? WHERE id = ?", .real(date.timeIntervalSince1970), .int(id))
    }

    /// Record a manual correction of `seconds` (positive or negative) against a task, dated now.
    func addAdjustment(taskID: Int64, seconds: Double) {
        let t = Date().timeIntervalSince1970
        run("INSERT INTO segments (task_id, start, end, manual) VALUES (?, ?, ?, 1)",
            .int(taskID), .real(t), .real(t + seconds))
    }

    // MARK: Plumbing

    enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.exec(msg)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Cronom SQL error: %@ — %@", String(cString: sqlite3_errmsg(db)), sql)
            return nil
        }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: Value...) {
        guard let stmt = prepare(sql, values) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Cronom SQL error: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ values: Value..., row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, values) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
