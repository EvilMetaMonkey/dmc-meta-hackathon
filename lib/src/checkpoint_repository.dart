import 'checkpoint_models.dart';
import 'database.dart';

class CheckpointRepository {
  final DmcDatabase database;

  const CheckpointRepository(this.database);

  CheckpointRecord? getCheckpoint(String id) {
    final rows = database.db.select(
      'SELECT * FROM checkpoints WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : _checkpoint(rows.single);
  }

  CheckpointRecord? getActiveCheckpoint() {
    final rows = database.db.select(
      "SELECT * FROM checkpoints WHERE status IN ('creating', 'open', 'closing') ORDER BY created_at DESC LIMIT 1",
    );
    return rows.isEmpty ? null : _checkpoint(rows.single);
  }

  CheckpointRecord? getLatestCheckpoint() {
    final rows = database.db.select(
      'SELECT * FROM checkpoints ORDER BY created_at DESC, id DESC LIMIT 1',
    );
    return rows.isEmpty ? null : _checkpoint(rows.single);
  }

  List<CheckpointRecord> listCheckpoints({int limit = 50}) => database.db
      .select(
        'SELECT * FROM checkpoints ORDER BY created_at DESC, id DESC LIMIT ?',
        [limit],
      )
      .map(_checkpoint)
      .toList();

  void createCheckpoint({
    required String id,
    required String? label,
    required String source,
    required int createdAt,
    required String policyFingerprint,
    CheckpointAgentContext? agent,
  }) {
    database.db.execute(
      '''
      INSERT INTO checkpoints
        (id, label, source, status, manifest_version, created_at,
         policy_fingerprint, fatal_error_count, exclusion_count,
         agent, agent_session_id, agent_turn_id, agent_transcript_path)
      VALUES (?, ?, ?, 'creating', 1, ?, ?, 0, 0, ?, ?, ?, ?)
      ''',
      [
        id,
        label,
        source,
        createdAt,
        policyFingerprint,
        agent?.agent,
        agent?.sessionId,
        agent?.turnId,
        agent?.transcriptPath,
      ],
    );
  }

  /// Record the agent transcript observed at close. A null [bytes] or
  /// [sha256] means the transcript could not be read.
  void setAgentTranscript(
    String id, {
    required String? path,
    required int? bytes,
    required String? sha256,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoints SET agent_transcript_path = ?,
        agent_transcript_bytes = ?, agent_transcript_sha256 = ?
      WHERE id = ? AND agent IS NOT NULL
      ''',
      [path, bytes, sha256, id],
    );
  }

  void addBeforeFile({
    required String checkpointId,
    required String filePath,
    required int snapshotId,
    required String hash,
    required int? mode,
  }) {
    database.db.execute(
      '''
      INSERT INTO checkpoint_files
        (checkpoint_id, file_path, before_kind, before_snapshot_id, before_hash,
         before_mode)
      VALUES (?, ?, 'file', ?, ?, ?)
      ''',
      [checkpointId, filePath, snapshotId, hash, mode],
    );
  }

  void addCreatedFile({
    required String checkpointId,
    required String filePath,
    required int snapshotId,
    required String hash,
    required int? mode,
  }) {
    database.db.execute(
      '''
      INSERT INTO checkpoint_files
        (checkpoint_id, file_path, before_kind, after_kind,
         after_snapshot_id, after_hash, after_mode, change_kind)
      VALUES (?, ?, 'absent', 'file', ?, ?, ?, 'created')
      ''',
      [checkpointId, filePath, snapshotId, hash, mode],
    );
  }

  void setAfterFile({
    required String checkpointId,
    required String filePath,
    required int snapshotId,
    required String hash,
    required int? mode,
    required CheckpointChangeKind change,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoint_files
      SET after_kind = 'file', after_snapshot_id = ?, after_hash = ?, after_mode = ?,
          change_kind = ?
      WHERE checkpoint_id = ? AND file_path = ?
      ''',
      [snapshotId, hash, mode, change.name, checkpointId, filePath],
    );
  }

  /// A file protected at begin that the close-time policy no longer covers.
  void setLeftScope({required String checkpointId, required String filePath}) {
    database.db.execute(
      '''
      UPDATE checkpoint_files
      SET after_kind = NULL, after_snapshot_id = NULL, after_hash = NULL,
          after_mode = NULL, change_kind = NULL, scope_change = 'left_scope'
      WHERE checkpoint_id = ? AND file_path = ?
      ''',
      [checkpointId, filePath],
    );
  }

  /// A file the close-time policy covers but the begin-time policy excluded.
  /// It has no before state.
  void addEnteredScopeFile({
    required String checkpointId,
    required String filePath,
    required int snapshotId,
    required String hash,
    required int? mode,
  }) {
    database.db.execute(
      '''
      INSERT INTO checkpoint_files
        (checkpoint_id, file_path, before_kind, after_kind,
         after_snapshot_id, after_hash, after_mode, change_kind, scope_change)
      VALUES (?, ?, 'absent', 'file', ?, ?, ?, NULL, 'entered_scope')
      ''',
      [checkpointId, filePath, snapshotId, hash, mode],
    );
  }

  void setAfterAbsent({
    required String checkpointId,
    required String filePath,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoint_files
      SET after_kind = 'absent', after_snapshot_id = NULL, after_hash = NULL,
          after_mode = NULL,
          change_kind = 'deleted'
      WHERE checkpoint_id = ? AND file_path = ?
      ''',
      [checkpointId, filePath],
    );
  }

  void addIssue(CheckpointIssue issue) {
    database.db.execute(
      '''
      INSERT INTO checkpoint_issues
        (checkpoint_id, phase, file_path, code, message, fatal)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        issue.checkpointId,
        issue.phase,
        issue.filePath,
        issue.code,
        issue.message,
        issue.fatal ? 1 : 0,
      ],
    );
  }

  void finishBegin(
    String id, {
    required bool valid,
    required int fatalErrors,
    required int exclusions,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoints SET status = ?, fatal_error_count = ?,
        exclusion_count = ? WHERE id = ?
      ''',
      [valid ? 'open' : 'invalid', fatalErrors, exclusions, id],
    );
  }

  void prepareClose(String id) {
    database.transaction(() {
      database.db.execute(
        "UPDATE checkpoints SET status = 'closing', closed_at = NULL WHERE id = ? AND status IN ('open', 'closing')",
        [id],
      );
      database.db.execute(
        'DELETE FROM checkpoint_issues WHERE checkpoint_id = ? AND phase = ?',
        [id, 'close'],
      );
      database.db.execute(
        "DELETE FROM checkpoint_files WHERE checkpoint_id = ? AND before_kind = 'absent'",
        [id],
      );
      database.db.execute(
        '''
        UPDATE checkpoint_files
        SET after_kind = NULL, after_snapshot_id = NULL, after_hash = NULL,
            after_mode = NULL,
            change_kind = NULL, scope_change = NULL
        WHERE checkpoint_id = ?
        ''',
        [id],
      );
    });
  }

  void finishClose(
    String id, {
    required bool valid,
    required int closedAt,
    required int fatalErrors,
    required int exclusions,
    String? closePolicyFingerprint,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoints SET status = ?, closed_at = ?,
        fatal_error_count = ?, exclusion_count = ?,
        close_policy_fingerprint = ? WHERE id = ?
      ''',
      [
        valid ? 'closed' : 'invalid',
        closedAt,
        fatalErrors,
        exclusions,
        closePolicyFingerprint,
        id,
      ],
    );
  }

  void release(String id, int releasedAt) {
    database.transaction(() {
      final incomplete = database.db.select(
        "SELECT 1 FROM checkpoint_operations WHERE checkpoint_id = ? AND status IN ('planned', 'applying', 'failed', 'rolling_back') LIMIT 1",
        [id],
      );
      if (incomplete.isNotEmpty) {
        throw StateError(
          'Checkpoint has an incomplete restore operation. Recover it before release.',
        );
      }
      database.db.execute(
        '''
        UPDATE checkpoint_operation_files
        SET intended_snapshot_id = NULL, pre_snapshot_id = NULL
        WHERE operation_id IN
          (SELECT id FROM checkpoint_operations WHERE checkpoint_id = ?)
        ''',
        [id],
      );
      database.db.execute(
        '''
        UPDATE checkpoint_files
        SET before_snapshot_id = NULL, after_snapshot_id = NULL
        WHERE checkpoint_id = ?
        ''',
        [id],
      );
      database.db.execute(
        "UPDATE checkpoints SET status = 'released', released_at = ? WHERE id = ?",
        [releasedAt, id],
      );
    });
  }

  List<CheckpointFileRecord> getFiles(String checkpointId) {
    return database.db
        .select(
          'SELECT * FROM checkpoint_files WHERE checkpoint_id = ? ORDER BY file_path ASC',
          [checkpointId],
        )
        .map(_file)
        .toList();
  }

  List<CheckpointIssue> getIssues(String checkpointId) {
    return database.db
        .select(
          'SELECT * FROM checkpoint_issues WHERE checkpoint_id = ? ORDER BY fatal DESC, phase ASC, COALESCE(file_path, \'\') ASC, id ASC',
          [checkpointId],
        )
        .map(_issue)
        .toList();
  }

  CheckpointView? getView(String id) {
    final checkpoint = getCheckpoint(id);
    return checkpoint == null
        ? null
        : CheckpointView(
            checkpoint: checkpoint,
            files: getFiles(id),
            issues: getIssues(id),
          );
  }

  CheckpointRecord _checkpoint(dynamic row) => CheckpointRecord(
    id: row['id'] as String,
    label: row['label'] as String?,
    source: row['source'] as String,
    status: checkpointStatusFromText(row['status'] as String),
    manifestVersion: row['manifest_version'] as int,
    createdAt: row['created_at'] as int,
    closedAt: row['closed_at'] as int?,
    releasedAt: row['released_at'] as int?,
    policyFingerprint: row['policy_fingerprint'] as String,
    closePolicyFingerprint: row['close_policy_fingerprint'] as String?,
    fatalErrorCount: row['fatal_error_count'] as int,
    exclusionCount: row['exclusion_count'] as int,
    agent: row['agent'] == null
        ? null
        : CheckpointAgentContext(
            agent: row['agent'] as String,
            sessionId: row['agent_session_id'] as String?,
            turnId: row['agent_turn_id'] as String?,
            transcriptPath: row['agent_transcript_path'] as String?,
            transcriptBytes: row['agent_transcript_bytes'] as int?,
            transcriptSha256: row['agent_transcript_sha256'] as String?,
          ),
  );

  CheckpointFileRecord _file(dynamic row) => CheckpointFileRecord(
    checkpointId: row['checkpoint_id'] as String,
    filePath: row['file_path'] as String,
    beforeKind: checkpointFileKindFromText(row['before_kind'] as String),
    beforeSnapshotId: row['before_snapshot_id'] as int?,
    beforeHash: row['before_hash'] as String?,
    beforeMode: row['before_mode'] as int?,
    afterKind: row['after_kind'] == null
        ? null
        : checkpointFileKindFromText(row['after_kind'] as String),
    afterSnapshotId: row['after_snapshot_id'] as int?,
    afterHash: row['after_hash'] as String?,
    afterMode: row['after_mode'] as int?,
    changeKind: checkpointChangeKindFromText(row['change_kind'] as String?),
    scopeChange: CheckpointScopeChange.fromText(row['scope_change'] as String?),
  );

  CheckpointIssue _issue(dynamic row) => CheckpointIssue(
    id: row['id'] as int,
    checkpointId: row['checkpoint_id'] as String,
    phase: row['phase'] as String,
    filePath: row['file_path'] as String?,
    code: row['code'] as String,
    message: row['message'] as String,
    fatal: (row['fatal'] as int) == 1,
  );
}
