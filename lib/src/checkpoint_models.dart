enum CheckpointStatus { creating, open, closing, closed, invalid, released }

enum CheckpointFileKind { file, absent }

enum CheckpointChangeKind { unchanged, modified, created, deleted }

/// How a file's protection changed when the ignore policy changed between
/// begin and close. Such files have a null change classification.
enum CheckpointScopeChange {
  /// In scope at begin, out of scope at close (newly ignored). The before
  /// state is kept; there is no after state, and restore and redo skip it.
  leftScope('left_scope'),

  /// Out of scope at begin, in scope at close (newly un-ignored). There is no
  /// before state (recorded as absent); restore never deletes or overwrites
  /// it, and redo only confirms it still matches its after state.
  enteredScope('entered_scope');

  final String id;
  const CheckpointScopeChange(this.id);

  static CheckpointScopeChange? fromText(String? value) => value == null
      ? null
      : CheckpointScopeChange.values.firstWhere(
          (scope) => scope.id == value,
          orElse: () =>
              throw FormatException('Unknown checkpoint scope change: $value'),
        );
}

CheckpointStatus checkpointStatusFromText(String value) =>
    CheckpointStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => throw FormatException('Unknown checkpoint status: $value'),
    );

CheckpointFileKind checkpointFileKindFromText(String value) =>
    CheckpointFileKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () =>
          throw FormatException('Unknown checkpoint file kind: $value'),
    );

CheckpointChangeKind? checkpointChangeKindFromText(String? value) =>
    value == null
    ? null
    : CheckpointChangeKind.values.firstWhere(
        (kind) => kind.name == value,
        orElse: () => throw FormatException(
          'Unknown checkpoint change classification: $value',
        ),
      );

/// Which coding-agent turn a checkpoint brackets. Recorded by agent hooks;
/// null for manual and Haven checkpoints.
class CheckpointAgentContext {
  final String agent;
  final String? sessionId;
  final String? turnId;
  final String? transcriptPath;

  /// Transcript size and SHA-256 of the bytes read when the checkpoint closed.
  final int? transcriptBytes;
  final String? transcriptSha256;

  const CheckpointAgentContext({
    required this.agent,
    this.sessionId,
    this.turnId,
    this.transcriptPath,
    this.transcriptBytes,
    this.transcriptSha256,
  });

  Map<String, Object?> toJson() => {
    'name': agent,
    'sessionId': sessionId,
    'turnId': turnId,
    'transcriptPath': transcriptPath,
    'transcriptBytes': transcriptBytes,
    'transcriptSha256': transcriptSha256,
  };
}

class CheckpointRecord {
  final String id;
  final String? label;
  final String source;
  final CheckpointStatus status;
  final int manifestVersion;
  final int createdAt;
  final int? closedAt;
  final int? releasedAt;
  final String policyFingerprint;

  /// The policy fingerprint at close; differs from [policyFingerprint] when
  /// the ignore policy changed during the checkpoint. Null before close and
  /// for checkpoints closed before schema 5.
  final String? closePolicyFingerprint;
  final int fatalErrorCount;
  final int exclusionCount;
  final CheckpointAgentContext? agent;

  const CheckpointRecord({
    required this.id,
    required this.label,
    required this.source,
    required this.status,
    required this.manifestVersion,
    required this.createdAt,
    required this.closedAt,
    required this.releasedAt,
    required this.policyFingerprint,
    this.closePolicyFingerprint,
    required this.fatalErrorCount,
    required this.exclusionCount,
    this.agent,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'source': source,
    'status': status.name,
    'manifestVersion': manifestVersion,
    'createdAt': createdAt,
    'closedAt': closedAt,
    'releasedAt': releasedAt,
    'policyFingerprint': policyFingerprint,
    'closePolicyFingerprint': closePolicyFingerprint,
    'fatalErrorCount': fatalErrorCount,
    'exclusionCount': exclusionCount,
    'agent': agent?.toJson(),
  };
}

class CheckpointFileRecord {
  final String checkpointId;
  final String filePath;
  final CheckpointFileKind beforeKind;
  final int? beforeSnapshotId;
  final String? beforeHash;
  final int? beforeMode;
  final CheckpointFileKind? afterKind;
  final int? afterSnapshotId;
  final String? afterHash;
  final int? afterMode;
  final CheckpointChangeKind? changeKind;
  final CheckpointScopeChange? scopeChange;

  const CheckpointFileRecord({
    required this.checkpointId,
    required this.filePath,
    required this.beforeKind,
    required this.beforeSnapshotId,
    required this.beforeHash,
    required this.beforeMode,
    required this.afterKind,
    required this.afterSnapshotId,
    required this.afterHash,
    required this.afterMode,
    required this.changeKind,
    this.scopeChange,
  });

  Map<String, Object?> toJson() => {
    'path': filePath,
    'before': {
      'kind': beforeKind.name,
      'snapshotId': beforeSnapshotId,
      'hash': beforeHash,
      'mode': beforeMode,
    },
    'after': afterKind == null
        ? null
        : {
            'kind': afterKind!.name,
            'snapshotId': afterSnapshotId,
            'hash': afterHash,
            'mode': afterMode,
          },
    'change': changeKind?.name,
    'scope': scopeChange?.id,
  };
}

class CheckpointIssue {
  final int? id;
  final String checkpointId;
  final String phase;
  final String? filePath;
  final String code;
  final String message;
  final bool fatal;

  const CheckpointIssue({
    this.id,
    required this.checkpointId,
    required this.phase,
    required this.filePath,
    required this.code,
    required this.message,
    required this.fatal,
  });

  Map<String, Object?> toJson() => {
    'phase': phase,
    'path': filePath,
    'code': code,
    'message': message,
    'fatal': fatal,
  };
}

class CheckpointView {
  final CheckpointRecord checkpoint;
  final List<CheckpointFileRecord> files;
  final List<CheckpointIssue> issues;

  const CheckpointView({
    required this.checkpoint,
    required this.files,
    required this.issues,
  });

  int get protectedFileCount =>
      files.where((file) => file.beforeKind == CheckpointFileKind.file).length;
  int get changedFileCount => files
      .where(
        (file) =>
            file.changeKind != null &&
            file.changeKind != CheckpointChangeKind.unchanged,
      )
      .length;

  Map<String, Object?> toJson({bool includeFiles = true}) => {
    'checkpoint': {
      ...checkpoint.toJson(),
      'protectedFileCount': protectedFileCount,
      'changedFileCount': changedFileCount,
    },
    if (includeFiles) 'files': files.map((file) => file.toJson()).toList(),
    'issues': issues.map((issue) => issue.toJson()).toList(),
  };
}
