import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'config.dart';
import 'database.dart';
import 'file_policy.dart';
import 'git_ignore.dart';
import 'ignore.dart';
import 'snapshot_store.dart';
import 'task.dart';
import 'workspace.dart';
import 'workspace_scan.dart';
import 'watcher_control.dart';

/// Debounce delay in milliseconds
const int debounceDelayMs = 500;

/// Snapshots captured within this window share the same burst id.
const Duration burstWindow = Duration(seconds: 3);

class BurstAssigner {
  final Duration window;
  int? _activeBurstId;
  int? _lastSnapshotTimestamp;

  BurstAssigner({this.window = burstWindow});

  int assignBurstId(int timestamp) {
    if (_activeBurstId == null ||
        _lastSnapshotTimestamp == null ||
        timestamp - _lastSnapshotTimestamp! > window.inMilliseconds) {
      _activeBurstId = timestamp;
    }

    _lastSnapshotTimestamp = timestamp;
    return _activeBurstId!;
  }
}

/// Watches a directory for file changes and backs up modified files
class DmcWatcher {
  final String targetPath;
  final DmcDatabase database;
  final String snapshotsPath;
  final List<IgnoreRule> ignoreRules;

  /// In Git mode, Git decides what is ignored before [ignoreRules] apply.
  /// Events are checked in one `git check-ignore` batch per drain.
  final GitWorkTree? git;
  final BurstAssigner burstAssigner;
  final int Function() _nowMilliseconds;
  final int maxFileSizeBytes;
  final String? Function() _activeTaskNameProvider;

  final Map<String, Timer> _pendingBackups = {};
  final Set<String> _queuedPaths = {};
  final Map<String, StreamSubscription<FileSystemEvent>> _subscriptions = {};
  final Map<String, String> _captureErrors = {};
  final Map<String, String> _watchErrors = {};
  final Map<String, String> _exclusions = {};
  Map<String, String> _scanErrors = {};
  Future<void> _work = Future<void>.value();
  Future<bool>? _starting;
  Future<void>? _stopping;
  Future<void>? _scan;
  Timer? _reconcileTimer;
  bool _acceptEvents = false;
  String _phase = 'stopped';
  final Duration reconciliationInterval;
  final SnapshotStore? snapshotStore;
  late final String _normalizedTargetPath;

  DmcWatcher({
    required this.targetPath,
    required this.database,
    required this.snapshotsPath,
    required this.ignoreRules,
    this.git,
    required this.maxFileSizeBytes,
    String? Function()? activeTaskNameProvider,
    BurstAssigner? burstAssigner,
    int Function()? nowMilliseconds,
    this.reconciliationInterval = const Duration(seconds: 2),
    this.snapshotStore,
  }) : burstAssigner = burstAssigner ?? BurstAssigner(),
       _activeTaskNameProvider = activeTaskNameProvider ?? (() => null),
       _nowMilliseconds =
           nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _normalizedTargetPath = p.normalize(targetPath);
  }

  DmcPaths get _paths => DmcPaths(basePath: targetPath);
  bool get hasErrors =>
      _captureErrors.isNotEmpty ||
      _watchErrors.isNotEmpty ||
      _scanErrors.isNotEmpty;
  bool get isReady => _phase == 'ready' && !hasErrors;
  Map<String, Object?> get health => {
    'version': 1,
    'pid': pid,
    'phase': hasErrors && _phase == 'ready' ? 'degraded' : _phase,
    'ready': isReady,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
    'errors': {..._scanErrors, ..._captureErrors, ..._watchErrors},
    'exclusions': _exclusions,
    'pending': _queuedPaths.length,
  };

  void _publishHealth() {
    try {
      writeControlJson(_paths, 'watcher-health.json', health);
    } catch (e) {
      _watchErrors['health'] = 'Cannot persist watcher health: $e';
      print('[DMC] Cannot persist watcher health: $e');
    }
  }

  /// Subscribe before reading the baseline. Reconcile on every start so an
  /// existing vault also records changes/deletions made while DMC was stopped.
  Future<bool> start() => _starting ??= _start();
  Future<bool> _start() async {
    _phase = 'starting';
    _acceptEvents = true;
    _publishHealth();
    await _reconcile();
    for (var pass = 0; pass < 5 && _queuedPaths.isNotEmpty; pass++) {
      await _drainPending();
    }
    if (_queuedPaths.isNotEmpty) {
      _watchErrors['startup'] =
          'Workspace is changing too quickly to establish readiness. Stop writers and restart.';
    }
    _phase = hasErrors ? 'degraded' : 'ready';
    _publishHealth();
    if (!hasErrors) {
      print(
        '[DMC] Ready: baseline captured; watching $targetPath (${_exclusions.length} excluded path(s)).',
      );
    } else {
      print('[DMC] Watcher is not ready. Run dmc doctor for capture errors.');
    }
    _reconcileTimer = Timer.periodic(
      reconciliationInterval,
      (_) => _reconcile(),
    );
    return isReady;
  }

  void _subscribe(String directory) {
    if (!_acceptEvents || _subscriptions.containsKey(directory)) return;
    _subscriptions[directory] = Directory(directory).watch().listen(
      _handleFileEvent,
      onError: (Object error) {
        _watchErrors[directory] = error.toString();
        _publishHealth();
      },
    );
  }

  Future<void> _reconcile() =>
      _scan ??= _scanWorkspace().whenComplete(() => _scan = null);
  Future<void> _scanWorkspace() async {
    try {
      final scan = await scanWorkspace(
        _paths,
        ignoreRules,
        git: git,
        onDirectory: _subscribe,
      );
      _scanErrors = scan.errors;
      _exclusions
        ..clear()
        ..addAll(scan.exclusions);
      if (scan.errors.isNotEmpty) {
        _publishHealth();
        return;
      }
      for (final path in scan.files) {
        await captureFileNow(path);
      }
      // History paths missing from the scan may have been deleted. Ignored,
      // linked or unreadable paths must never be inferred to be deletions.
      final historicalPaths = database
          .getAllSnapshotRecords()
          .map((row) => row.filePath)
          .toSet();
      final missing = [
        for (final relative in historicalPaths)
          if (shouldTrackFile(p.join(targetPath, relative)) &&
              FileSystemEntity.typeSync(
                    p.join(targetPath, relative),
                    followLinks: false,
                  ) ==
                  FileSystemEntityType.notFound)
            relative,
      ];
      final gitIgnored = git == null || missing.isEmpty
          ? const <String>{}
          : await git!.ignoredAmong(missing);
      for (final relative in missing) {
        if (gitIgnored.contains(relative)) continue;
        await captureFileNow(p.join(targetPath, relative));
      }
      for (final directory in _subscriptions.keys.toList()) {
        if (!scan.directories.contains(directory)) {
          await _subscriptions.remove(directory)?.cancel();
        }
      }
    } catch (e) {
      _scanErrors['scan'] = e.toString();
    }
    _publishHealth();
  }

  /// Capture a file immediately without debounce. Useful for focused tests.
  Future<CaptureResult> captureFileNow(String filePath) async {
    if (_scanErrors.isNotEmpty) {
      return const CaptureResult(
        CaptureStatus.failed,
        message: 'Workspace scan has unresolved errors; capture paused',
      );
    }
    final normalizedPath = p.normalize(filePath);
    if (_isIgnored(normalizedPath)) {
      return const CaptureResult(CaptureStatus.skipped);
    }

    final result = Completer<CaptureResult>();
    _work = _work.then((_) async {
      final captured = await _performBackup(normalizedPath);
      if (captured.hadError) {
        _captureErrors[normalizedPath] = captured.message ?? 'Capture failed';
      } else {
        _captureErrors.remove(normalizedPath);
        if (captured.status == CaptureStatus.skipped &&
            captured.message != null) {
          _exclusions[p.relative(normalizedPath, from: targetPath)] =
              captured.message!;
        }
      }
      result.complete(captured);
    });
    return result.future;
  }

  /// Stop watching for file changes
  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    if (_starting != null) await _starting;
    _phase = 'stopping';
    _acceptEvents = false;
    _reconcileTimer?.cancel();
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final timer in _pendingBackups.values) {
      timer.cancel();
    }
    _pendingBackups.clear();
    if (_scan != null) await _scan;
    await _drainPending();
    await _reconcile();
    await _work;
    _phase = hasErrors ? 'failed' : 'stopped';
    _publishHealth();
    print(
      '[DMC] Stopped watching after draining pending captures${hasErrors ? ' (errors remain; run dmc doctor)' : ''}.',
    );
  }

  Future<void> _drainPending() async {
    final paths = _queuedPaths.toList();
    _queuedPaths.clear();
    final files = <String>[];
    for (final path in paths) {
      _pendingBackups.remove(path)?.cancel();
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        files.add(path);
      }
    }
    var gitIgnored = const <String>{};
    if (git != null && files.isNotEmpty) {
      try {
        gitIgnored = await git!.ignoredAmong([
          for (final path in files) p.relative(path, from: targetPath),
        ]);
        _scanErrors.remove('git');
      } on GitIgnoreException catch (error) {
        // Never capture or infer deletions without Git's verdict.
        _scanErrors['git'] = error.message;
        _publishHealth();
        return;
      }
    }
    for (final path in files) {
      if (gitIgnored.contains(p.relative(path, from: targetPath))) continue;
      await captureFileNow(path);
    }
    _publishHealth();
  }

  /// Handle a file system event
  void _handleFileEvent(FileSystemEvent event) {
    if (!_acceptEvents) return;
    for (final path in [
      event.path,
      if (event is FileSystemMoveEvent && event.destination != null)
        event.destination!,
    ]) {
      final filePath = p.normalize(path);
      if (_isIgnored(filePath, isDirectory: event.isDirectory)) continue;
      _queuedPaths.add(filePath);
      if (_phase == 'starting') continue;
      _pendingBackups[filePath]?.cancel();
      _pendingBackups[filePath] = Timer(
        const Duration(milliseconds: debounceDelayMs),
        () async {
          await _drainPending();
          if (event.isDirectory) await _reconcile();
        },
      );
    }
  }

  bool _isIgnored(String filePath, {bool isDirectory = false}) {
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

    if (relativePath == '..' || relativePath.startsWith('..${p.separator}')) {
      return true;
    }
    if (relativePath == '.') return true;

    for (final rule in ignoreRules) {
      if (rule.matches(relativePath, isDirectory: isDirectory)) {
        return true;
      }
    }
    try {
      _paths.resolveFile(filePath);
    } catch (_) {
      return true;
    }

    return false;
  }

  bool shouldTrackFile(String filePath) {
    return !_isIgnored(p.normalize(filePath));
  }

  /// Perform the backup for a file
  Future<CaptureResult> _performBackup(String filePath) async {
    // Calculate relative path from target directory
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

    try {
      final file = File(filePath);
      final timestamp = _nowMilliseconds();
      final burstId = burstAssigner.assignBurstId(timestamp);
      final taskName = _activeTaskNameProvider();

      if (await file.exists() && hasKnownBinaryExtension(file.path)) {
        print('[DMC] Skipping $relativePath: binary files are not tracked.');
        return const CaptureResult(
          CaptureStatus.skipped,
          message: 'binary files are not tracked',
        );
      }
      late CaptureResult result;
      for (var attempt = 0; attempt < 3; attempt++) {
        result =
            await (snapshotStore ??
                    SnapshotStore(
                      database: database,
                      snapshotsPath: snapshotsPath,
                    ))
                .captureFile(
                  source: file,
                  relativePath: relativePath,
                  timestamp: timestamp,
                  burstId: burstId,
                  taskName: taskName,
                  maxFileSizeBytes: maxFileSizeBytes,
                  skipContent: hasBinaryProbe,
                  requireStableRead: true,
                );
        if (!result.hadError ||
            !(result.message?.startsWith('Source changed during capture') ??
                false)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (result.hadError) {
        print('[DMC] Could not backup $relativePath: ${result.message}');
      } else if (result.status == CaptureStatus.captured) {
        final row = database.getSnapshotById(result.snapshotId!);
        final deletion =
            row != null &&
            isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath);
        print(
          '[DMC] Captured ${deletion ? 'deletion' : 'change'}: $relativePath',
        );
      } else if (result.message != null) {
        final message = result.message == 'file exceeds max size'
            ? '${result.message} (${maxFileSizeBytes ~/ 1024} KB)'
            : result.message;
        print('[DMC] Skipping $relativePath: $message.');
      }
      return result;
    } catch (e) {
      // Gracefully handle file read errors (e.g., locked files)
      print('[DMC] Could not backup $relativePath: $e');
      return CaptureResult(CaptureStatus.failed, message: e.toString());
    }
  }
}

/// Run one foreground or detached watcher with exclusive ownership and graceful
/// shutdown. The caller receives failure if readiness or final capture fails.
Future<int> watchDmc({String? basePath, Future<void>? keepAlive}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!paths.dmcDirectory.existsSync() || !File(paths.dbPath).existsSync()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }
  final db = DmcDatabase(paths.dbPath);
  DmcWatcher? watcher;
  WatcherControl? control;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    control = await WatcherControl.acquire(
      paths,
      state: () => watcher?.health ?? {'phase': 'starting', 'ready': false},
    );
    writeControlJson(paths, 'daemon.pid', {'pid': pid});
    db.initialize();
    final config = await loadDmcConfig(basePath: paths.rootPath);
    final policy = await loadIgnorePolicy(paths.rootPath);
    watcher = DmcWatcher(
      targetPath: paths.rootPath,
      database: db,
      snapshotsPath: paths.snapshotsPath,
      ignoreRules: policy.rules,
      git: policy.git,
      maxFileSizeBytes: config.maxFileSizeBytes,
      activeTaskNameProvider: () =>
          readActiveTaskSync(basePath: paths.rootPath),
    );
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      signals.add(
        signal.watch().listen((_) {
          if (!control!.stopRequested.isCompleted) {
            control.stopRequested.complete();
          }
        }),
      );
    }
    if (!await watcher.start()) return 1;
    await Future.any([control.stopRequested.future, ?keepAlive]);
    await watcher.stop();
    return watcher.hasErrors ? 1 : 0;
  } catch (e) {
    print('[DMC] Watcher failed: $e');
    if (control != null) {
      writeControlJson(paths, 'watcher-health.json', {
        'version': 1,
        'pid': pid,
        'phase': 'failed',
        'ready': false,
        'errors': {'startup': e.toString()},
        'exclusions': {},
      });
    }
    return 1;
  } finally {
    for (final subscription in signals) {
      await subscription.cancel();
    }
    try {
      if (watcher != null) await watcher.stop();
    } finally {
      db.close();
      if (control != null) {
        try {
          final metadata = readControlJson(paths, 'daemon.pid');
          if (metadata?['pid'] == pid) paths.daemonPidFile.deleteSync();
        } finally {
          await control.close();
        }
      }
    }
  }
}
