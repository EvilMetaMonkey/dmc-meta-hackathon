import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const String tombstoneHash = 'TOMBSTONE';
const String tombstoneSnapshotPath = '__TOMBSTONE__';

bool isTombstoneSnapshot({required String hash, required String snapshotPath}) {
  return hash == tombstoneHash && snapshotPath == tombstoneSnapshotPath;
}

/// Database manager for DMC's SQLite storage
class DmcDatabase {
  static const schemaVersion = 5;
  final String dbPath;
  Database? _db;
  Directory? _readCopy;

  DmcDatabase(this.dbPath);

  /// Open an isolated read copy without touching source SQLite sidecars.
  /// Caller must hold the workspace lock and ensure its watcher is stopped.
  void openReadOnly() {
    if (_db != null) throw StateError('Database is already open.');
    try {
      // Even a SQLite read-only connection can create/change WAL shared memory.
      // Copy the stable database and WAL, never the transient shared-memory file.
      _readCopy = Directory.systemTemp.createTempSync('dmc-recovery-preview-');
      final copyPath = p.join(_readCopy!.path, 'metadata.db');
      for (final suffix in ['', '-wal']) {
        final source = '$dbPath$suffix';
        final type = FileSystemEntity.typeSync(source, followLinks: false);
        if (suffix.isNotEmpty && type == FileSystemEntityType.notFound) {
          continue;
        }
        if (type != FileSystemEntityType.file) {
          throw StateError('Recovery metadata must be a regular file.');
        }
        File(source).copySync('$copyPath$suffix');
      }
      _db = sqlite3.open(copyPath, mode: OpenMode.readOnly);
      _db!.execute('PRAGMA query_only = ON');
      final version = db.select('PRAGMA user_version').first.values.first;
      if (version != schemaVersion) {
        throw StateError(
          'Recovery preview requires database schema $schemaVersion; found $version.',
        );
      }
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Get the underlying database instance
  Database get db {
    if (_db == null) {
      throw StateError('Database not initialized. Call initialize() first.');
    }
    return _db!;
  }

  /// Initialize the database and create tables if they don't exist
  void initialize() {
    if (_db != null) return;
    _db = sqlite3.open(dbPath);
    try {
      _db!.execute('PRAGMA busy_timeout = 5000');
      _db!.execute('PRAGMA foreign_keys = ON');
      _db!.execute('PRAGMA synchronous = FULL');
      transaction(() {
        var version =
            db.select('PRAGMA user_version').first.values.first as int;
        if (version > schemaVersion) {
          throw StateError(
            'DMC database version $version is newer than supported version $schemaVersion.',
          );
        }
        if (version < 1) {
          _migrateToVersion1();
          db.execute('PRAGMA user_version = 1');
          version = 1;
        }
        if (version < 2) {
          _migrateToVersion2();
          db.execute('PRAGMA user_version = 2');
          version = 2;
        }
        if (version < 3) {
          _migrateToVersion3();
          db.execute('PRAGMA user_version = 3');
          version = 3;
        }
        if (version < 4) {
          _migrateToVersion4();
          db.execute('PRAGMA user_version = 4');
          version = 4;
        }
        if (version < 5) {
          _migrateToVersion5();
          db.execute('PRAGMA user_version = 5');
        }
      });
      _db!.execute('PRAGMA journal_mode = WAL');
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Run synchronous metadata work atomically. Do not pass an async callback.
  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      if (result is Future) {
        throw ArgumentError('Transactions must be synchronous.');
      }
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateToVersion1() {
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        hash TEXT NOT NULL,
        burst_id INTEGER,
        task_name TEXT
      )
    ''');

    final historyColumns = _db!.select('PRAGMA table_info(history)');
    final hasBurstIdColumn = historyColumns.any(
      (row) => row['name'] == 'burst_id',
    );
    final hasTaskNameColumn = historyColumns.any(
      (row) => row['name'] == 'task_name',
    );

    if (!hasBurstIdColumn) {
      _db!.execute('ALTER TABLE history ADD COLUMN burst_id INTEGER');
    }
    if (!hasTaskNameColumn) {
      _db!.execute('ALTER TABLE history ADD COLUMN task_name TEXT');
    }

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS marks (
        name TEXT PRIMARY KEY,
        burst_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS restore_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        command TEXT NOT NULL,
        file_path TEXT NOT NULL,
        snapshot_id INTEGER NOT NULL,
        success INTEGER NOT NULL,
        failure_message TEXT,
        overwritten_snapshot_id INTEGER
      )
    ''');

    final restoreEventColumns = _db!.select(
      'PRAGMA table_info(restore_events)',
    );
    final hasCommandColumn = restoreEventColumns.any(
      (row) => row['name'] == 'command',
    );
    final hasLegacyCommandNameColumn = restoreEventColumns.any(
      (row) => row['name'] == 'command_name',
    );
    final hasOverwrittenSnapshotIdColumn = restoreEventColumns.any(
      (row) => row['name'] == 'overwritten_snapshot_id',
    );

    if (!hasCommandColumn) {
      _db!.execute('ALTER TABLE restore_events ADD COLUMN command TEXT');
    }

    if (hasLegacyCommandNameColumn) {
      _db!.execute(
        'UPDATE restore_events SET command = command_name WHERE command IS NULL',
      );
    }

    if (!hasOverwrittenSnapshotIdColumn) {
      _db!.execute(
        'ALTER TABLE restore_events ADD COLUMN overwritten_snapshot_id INTEGER',
      );
    }
  }

  void _migrateToVersion2() {
    _db!.execute('''
      CREATE TABLE checkpoints (
        id TEXT PRIMARY KEY,
        label TEXT,
        source TEXT NOT NULL CHECK(length(source) > 0),
        status TEXT NOT NULL CHECK(status IN
          ('creating', 'open', 'closing', 'closed', 'invalid', 'released')),
        manifest_version INTEGER NOT NULL CHECK(manifest_version = 1),
        created_at INTEGER NOT NULL,
        closed_at INTEGER,
        released_at INTEGER,
        policy_fingerprint TEXT NOT NULL,
        fatal_error_count INTEGER NOT NULL DEFAULT 0 CHECK(fatal_error_count >= 0),
        exclusion_count INTEGER NOT NULL DEFAULT 0 CHECK(exclusion_count >= 0)
      )
    ''');
    _db!.execute('''
      CREATE UNIQUE INDEX one_active_checkpoint
      ON checkpoints ((1))
      WHERE status IN ('creating', 'open', 'closing')
    ''');
    _db!.execute('''
      CREATE TABLE checkpoint_files (
        checkpoint_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        before_kind TEXT NOT NULL CHECK(before_kind IN ('file', 'absent')),
        before_snapshot_id INTEGER,
        before_hash TEXT,
        after_kind TEXT CHECK(after_kind IS NULL OR after_kind IN ('file', 'absent')),
        after_snapshot_id INTEGER,
        after_hash TEXT,
        change_kind TEXT CHECK(change_kind IS NULL OR change_kind IN
          ('unchanged', 'modified', 'created', 'deleted')),
        PRIMARY KEY (checkpoint_id, file_path),
        FOREIGN KEY (checkpoint_id) REFERENCES checkpoints(id) ON DELETE CASCADE,
        FOREIGN KEY (before_snapshot_id) REFERENCES history(id) ON DELETE RESTRICT,
        FOREIGN KEY (after_snapshot_id) REFERENCES history(id) ON DELETE RESTRICT,
        CHECK((before_kind = 'file' AND before_hash IS NOT NULL)
          OR (before_kind = 'absent' AND before_snapshot_id IS NULL AND before_hash IS NULL)),
        CHECK(after_kind IS NULL
          OR (after_kind = 'file' AND after_hash IS NOT NULL)
          OR (after_kind = 'absent' AND after_snapshot_id IS NULL AND after_hash IS NULL))
      )
    ''');
    _db!.execute('''
      CREATE TABLE checkpoint_issues (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        checkpoint_id TEXT NOT NULL,
        phase TEXT NOT NULL CHECK(phase IN ('begin', 'close')),
        file_path TEXT,
        code TEXT NOT NULL,
        message TEXT NOT NULL,
        fatal INTEGER NOT NULL CHECK(fatal IN (0, 1)),
        FOREIGN KEY (checkpoint_id) REFERENCES checkpoints(id) ON DELETE CASCADE
      )
    ''');
    _db!.execute(
      'CREATE INDEX checkpoint_issues_checkpoint ON checkpoint_issues(checkpoint_id, fatal)',
    );
  }

  void _migrateToVersion3() {
    _db!.execute(
      'ALTER TABLE checkpoint_files ADD COLUMN before_mode INTEGER CHECK(before_mode IS NULL OR before_mode BETWEEN 0 AND 511)',
    );
    _db!.execute(
      'ALTER TABLE checkpoint_files ADD COLUMN after_mode INTEGER CHECK(after_mode IS NULL OR after_mode BETWEEN 0 AND 511)',
    );
    _db!.execute('''
      CREATE TABLE checkpoint_operations (
        id TEXT PRIMARY KEY,
        checkpoint_id TEXT NOT NULL,
        direction TEXT NOT NULL CHECK(direction IN ('restore', 'redo')),
        status TEXT NOT NULL CHECK(status IN
          ('planned', 'applying', 'completed', 'failed',
           'rolling_back', 'rolled_back')),
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        completed_at INTEGER,
        failure_message TEXT,
        FOREIGN KEY (checkpoint_id) REFERENCES checkpoints(id) ON DELETE RESTRICT
      )
    ''');
    _db!.execute('''
      CREATE INDEX checkpoint_operations_checkpoint
      ON checkpoint_operations(checkpoint_id, created_at, id)
    ''');
    _db!.execute('''
      CREATE TABLE checkpoint_operation_files (
        operation_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence >= 0),
        file_path TEXT NOT NULL,
        expected_kind TEXT NOT NULL CHECK(expected_kind IN ('file', 'absent')),
        expected_hash TEXT,
        expected_mode INTEGER CHECK(expected_mode IS NULL OR expected_mode BETWEEN 0 AND 511),
        intended_kind TEXT NOT NULL CHECK(intended_kind IN ('file', 'absent')),
        intended_snapshot_id INTEGER,
        intended_hash TEXT,
        intended_mode INTEGER CHECK(intended_mode IS NULL OR intended_mode BETWEEN 0 AND 511),
        pre_kind TEXT NOT NULL CHECK(pre_kind IN ('file', 'absent')),
        pre_snapshot_id INTEGER,
        pre_hash TEXT,
        pre_mode INTEGER CHECK(pre_mode IS NULL OR pre_mode BETWEEN 0 AND 511),
        status TEXT NOT NULL CHECK(status IN ('pending', 'applied', 'rolled_back')),
        error TEXT,
        recovery_name TEXT NOT NULL,
        PRIMARY KEY (operation_id, file_path),
        UNIQUE (operation_id, sequence),
        FOREIGN KEY (operation_id) REFERENCES checkpoint_operations(id) ON DELETE CASCADE,
        FOREIGN KEY (intended_snapshot_id) REFERENCES history(id) ON DELETE RESTRICT,
        FOREIGN KEY (pre_snapshot_id) REFERENCES history(id) ON DELETE RESTRICT,
        CHECK((expected_kind = 'file' AND expected_hash IS NOT NULL)
          OR (expected_kind = 'absent' AND expected_hash IS NULL
              AND expected_mode IS NULL)),
        CHECK((intended_kind = 'file' AND intended_hash IS NOT NULL)
          OR (intended_kind = 'absent' AND intended_snapshot_id IS NULL
              AND intended_hash IS NULL AND intended_mode IS NULL)),
        CHECK((pre_kind = 'file' AND pre_hash IS NOT NULL)
          OR (pre_kind = 'absent' AND pre_snapshot_id IS NULL
              AND pre_hash IS NULL AND pre_mode IS NULL))
      )
    ''');
  }

  /// Agent-turn context for checkpoints begun by agent hooks. All columns are
  /// nullable so existing checkpoints keep their meaning.
  void _migrateToVersion4() {
    final existing = {
      for (final row in _db!.select('PRAGMA table_info(checkpoints)'))
        row['name'] as String,
    };
    for (final column in [
      'agent TEXT CHECK(agent IS NULL OR length(agent) > 0)',
      'agent_session_id TEXT',
      'agent_turn_id TEXT',
      'agent_transcript_path TEXT',
      'agent_transcript_bytes INTEGER CHECK(agent_transcript_bytes IS NULL OR agent_transcript_bytes >= 0)',
      'agent_transcript_sha256 TEXT',
    ]) {
      if (existing.contains(column.split(' ').first)) continue;
      _db!.execute('ALTER TABLE checkpoints ADD COLUMN $column');
    }
  }

  /// Ignore-policy drift during a checkpoint: the close-time policy
  /// fingerprint, and per-file scope changes. Nullable and additive; existing
  /// rows are not rewritten.
  void _migrateToVersion5() {
    final checkpointColumns = {
      for (final row in _db!.select('PRAGMA table_info(checkpoints)'))
        row['name'] as String,
    };
    if (!checkpointColumns.contains('close_policy_fingerprint')) {
      _db!.execute(
        'ALTER TABLE checkpoints ADD COLUMN close_policy_fingerprint TEXT',
      );
    }
    final fileColumns = {
      for (final row in _db!.select('PRAGMA table_info(checkpoint_files)'))
        row['name'] as String,
    };
    if (!fileColumns.contains('scope_change')) {
      _db!.execute(
        "ALTER TABLE checkpoint_files ADD COLUMN scope_change TEXT CHECK(scope_change IS NULL OR scope_change IN ('left_scope', 'entered_scope'))",
      );
    }
  }

  /// Close the database connection
  void close() {
    _db?.close();
    _db = null;
    final readCopy = _readCopy;
    _readCopy = null;
    if (readCopy != null && readCopy.existsSync()) {
      readCopy.deleteSync(recursive: true);
    }
  }

  /// Check if the history table exists
  bool get isInitialized {
    if (_db == null) return false;
    try {
      final result = _db!.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='history'",
      );
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Get the latest snapshot for a given file path
  /// Returns snapshot metadata or null if no previous snapshot exists.
  ({int id, String snapshotPath, int timestamp, String hash, int? burstId})?
  getLatestSnapshot(String filePath) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, snapshot_path, timestamp, hash, burst_id FROM history WHERE file_path = ? ORDER BY timestamp DESC, id DESC LIMIT 1',
      [filePath],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
      burstId: result.first['burst_id'] as int?,
    );
  }

  /// Insert a new snapshot record
  void insertSnapshot({
    required String filePath,
    required String snapshotPath,
    required int timestamp,
    required String hash,
    int? burstId,
    String? taskName,
  }) {
    _db!.execute(
      'INSERT INTO history (file_path, snapshot_path, timestamp, hash, burst_id, task_name) VALUES (?, ?, ?, ?, ?, ?)',
      [filePath, snapshotPath, timestamp, hash, burstId, taskName],
    );
  }

  void insertTombstone({
    required String filePath,
    required int timestamp,
    int? burstId,
    String? taskName,
  }) {
    insertSnapshot(
      filePath: filePath,
      snapshotPath: tombstoneSnapshotPath,
      timestamp: timestamp,
      hash: tombstoneHash,
      burstId: burstId,
      taskName: taskName,
    );
  }

  /// Get recent backup history ordered by timestamp descending.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getRecentHistory({int limit = 10}) {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name FROM history ORDER BY timestamp DESC LIMIT ?',
      [limit],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  /// Backwards-compatible alias for recent history retrieval.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getRecentLogs({int limit = 10}) {
    return getRecentHistory(limit: limit);
  }

  int getHistoryCount() {
    if (_db == null) return 0;

    final result = _db!.select('SELECT COUNT(*) AS count FROM history');
    return result.first['count'] as int;
  }

  List<({String filePath, String snapshotPath, String hash})>
  getAllSnapshotRecords() {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT file_path, snapshot_path, hash FROM history',
    );

    return result
        .map(
          (row) => (
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            hash: row['hash'] as String,
          ),
        )
        .toList();
  }

  /// Get all snapshots associated with a specific burst id.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getSnapshotsForBurst(int burstId) {
    if (_db == null) return [];

    final result = _db!.select(
      '''
      SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name
      FROM history
      WHERE burst_id = ?
      ORDER BY timestamp DESC, id DESC
      ''',
      [burstId],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getSnapshotsForTask(String taskName) {
    if (_db == null) return [];

    final result = _db!.select(
      '''
      SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name
      FROM history
      WHERE task_name = ?
      ORDER BY timestamp DESC, id DESC
      ''',
      [taskName],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  /// Get a specific snapshot by database id.
  ({int id, String filePath, String snapshotPath, int timestamp, String hash})?
  getSnapshotById(int id) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, file_path, snapshot_path, timestamp, hash FROM history WHERE id = ? LIMIT 1',
      [id],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      filePath: result.first['file_path'] as String,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
    );
  }

  int? getLatestBurstId() {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT burst_id FROM history WHERE burst_id IS NOT NULL ORDER BY timestamp DESC, id DESC LIMIT 1',
    );

    if (result.isEmpty) return null;
    return result.first['burst_id'] as int?;
  }

  void upsertMark({
    required String name,
    required int burstId,
    required int createdAt,
  }) {
    _db!.execute(
      '''
      INSERT INTO marks (name, burst_id, created_at)
      VALUES (?, ?, ?)
      ON CONFLICT(name) DO UPDATE SET
        burst_id = excluded.burst_id,
        created_at = excluded.created_at
      ''',
      [name, burstId, createdAt],
    );
  }

  List<({String name, int burstId, int createdAt})> getMarks() {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT name, burst_id, created_at FROM marks ORDER BY created_at DESC, name ASC',
    );

    return result
        .map(
          (row) => (
            name: row['name'] as String,
            burstId: row['burst_id'] as int,
            createdAt: row['created_at'] as int,
          ),
        )
        .toList();
  }

  ({String name, int burstId, int createdAt})? getMarkByName(String name) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT name, burst_id, created_at FROM marks WHERE name = ? LIMIT 1',
      [name],
    );

    if (result.isEmpty) return null;

    return (
      name: result.first['name'] as String,
      burstId: result.first['burst_id'] as int,
      createdAt: result.first['created_at'] as int,
    );
  }

  /// Get the most recent snapshot for a specific file path whose hash differs
  /// from the current working file.
  /// Returns (snapshot_path, timestamp) or null if no previous snapshot exists
  ({int id, String snapshotPath, int timestamp, String hash})?
  getSnapshotForRestore(String filePath, String currentHash) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, snapshot_path, timestamp, hash FROM history WHERE file_path = ? AND hash != ? ORDER BY timestamp DESC, id DESC LIMIT 1',
      [filePath, currentHash],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
    );
  }

  /// Insert a restore event record.
  void insertRestoreEvent({
    required int timestamp,
    required String command,
    required String filePath,
    required int snapshotId,
    required bool success,
    String? failureMessage,
    int? overwrittenSnapshotId,
  }) {
    // Legacy databases retain a required command_name column.
    final legacy = db
        .select('PRAGMA table_info(restore_events)')
        .any((row) => row['name'] == 'command_name');
    _db!.execute(
      'INSERT INTO restore_events (timestamp, command, file_path, snapshot_id, success, failure_message, overwritten_snapshot_id${legacy ? ', command_name' : ''}) VALUES (?, ?, ?, ?, ?, ?, ?${legacy ? ', ?' : ''})',
      [
        timestamp,
        command,
        filePath,
        snapshotId,
        success ? 1 : 0,
        failureMessage,
        overwrittenSnapshotId,
        if (legacy) command,
      ],
    );
  }

  /// Get recent restore audit records ordered by timestamp descending.
  List<
    ({
      int id,
      int timestamp,
      String command,
      String filePath,
      int snapshotId,
      bool success,
      String? failureMessage,
      int? overwrittenSnapshotId,
    })
  >
  getRecentRestoreEvents({int limit = 10}) {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT id, timestamp, command, file_path, snapshot_id, success, failure_message, overwritten_snapshot_id FROM restore_events ORDER BY timestamp DESC LIMIT ?',
      [limit],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            timestamp: row['timestamp'] as int,
            command: row['command'] as String,
            filePath: row['file_path'] as String,
            snapshotId: row['snapshot_id'] as int,
            success: (row['success'] as int) == 1,
            failureMessage: row['failure_message'] as String?,
            overwrittenSnapshotId: row['overwritten_snapshot_id'] as int?,
          ),
        )
        .toList();
  }

  ({
    int id,
    int timestamp,
    String command,
    String filePath,
    int snapshotId,
    bool success,
    String? failureMessage,
    int? overwrittenSnapshotId,
  })?
  getLatestRedoSourceEvent(String filePath) {
    if (_db == null) return null;

    final result = _db!.select(
      '''
      SELECT id, timestamp, command, file_path, snapshot_id, success,
             failure_message, overwritten_snapshot_id
      FROM restore_events
      WHERE file_path = ?
        AND success = 1
        AND command IN ('undo', 'restore')
      ORDER BY timestamp DESC, id DESC
      LIMIT 1
      ''',
      [filePath],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      timestamp: result.first['timestamp'] as int,
      command: result.first['command'] as String,
      filePath: result.first['file_path'] as String,
      snapshotId: result.first['snapshot_id'] as int,
      success: (result.first['success'] as int) == 1,
      failureMessage: result.first['failure_message'] as String?,
      overwrittenSnapshotId: result.first['overwritten_snapshot_id'] as int?,
    );
  }

  List<({int id, String snapshotPath, String hash})> getExpiredSnapshotRecords(
    Duration maxAge,
  ) {
    if (_db == null) return [];

    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final result = _db!.select(
      '''
      SELECT id, snapshot_path, hash
      FROM history
      WHERE timestamp < ?
        AND NOT EXISTS (SELECT 1 FROM marks WHERE marks.burst_id = history.burst_id)
        AND NOT EXISTS (
          SELECT 1
          FROM checkpoint_files cf
          JOIN checkpoints c ON c.id = cf.checkpoint_id
          WHERE c.status != 'released'
            AND (cf.before_snapshot_id = history.id OR cf.after_snapshot_id = history.id)
        )
        AND NOT EXISTS (
          SELECT 1
          FROM checkpoint_operation_files cof
          JOIN checkpoint_operations co ON co.id = cof.operation_id
          JOIN checkpoints c ON c.id = co.checkpoint_id
          WHERE c.status != 'released'
            AND (cof.intended_snapshot_id = history.id
              OR cof.pre_snapshot_id = history.id)
        )
        AND id NOT IN (
          SELECT snapshot_id FROM restore_events
          UNION
          SELECT overwritten_snapshot_id
          FROM restore_events
          WHERE overwritten_snapshot_id IS NOT NULL
        )
      ''',
      [cutoff],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            snapshotPath: row['snapshot_path'] as String,
            hash: row['hash'] as String,
          ),
        )
        .toList();
  }

  /// Detach eligible rows before removing blobs. Interrupted cleanup leaves
  /// orphan files, never committed rows pointing at files removed by GC.
  /// [deleteFile] permits callers to provide their filesystem deletion policy.
  Future<int> pruneOldSnapshots(
    Duration maxAge, {
    void Function(File file)? deleteFile,
  }) async {
    if (_db == null) return 0;
    final snapshotsPath = p.join(p.dirname(dbPath), 'snapshots');
    if (FileSystemEntity.typeSync(snapshotsPath, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'GC refuses symlinked snapshot storage',
        snapshotsPath,
      );
    }
    final expiredRows = transaction(() {
      final rows = getExpiredSnapshotRecords(maxAge);
      for (final row in rows) {
        db.execute('DELETE FROM history WHERE id = ?', [row.id]);
      }
      return rows;
    });
    final retained = getAllSnapshotRecords()
        .map((row) => row.snapshotPath)
        .toSet();
    final removed = <String>{};
    for (final row in expiredRows) {
      final snapshotPath = row.snapshotPath;
      if (isTombstoneSnapshot(hash: row.hash, snapshotPath: snapshotPath)) {
        continue;
      }
      if (retained.contains(snapshotPath) || !removed.add(snapshotPath)) {
        continue;
      }
      // Legacy names are flat filenames. Never unlink an arbitrary metadata path.
      if (p.basename(snapshotPath) != snapshotPath ||
          snapshotPath.contains('\\') ||
          snapshotPath == '.' ||
          snapshotPath == '..') {
        print('[DMC] GC left invalid snapshot path for doctor: $snapshotPath');
        continue;
      }
      final snapshotFile = File(p.join(snapshotsPath, snapshotPath));
      try {
        if (deleteFile != null) {
          deleteFile(snapshotFile);
        } else if (snapshotFile.existsSync()) {
          snapshotFile.deleteSync();
        }
      } on FileSystemException catch (e) {
        print('[DMC] GC left orphan $snapshotPath: $e');
      }
    }
    return expiredRows.length;
  }
}
