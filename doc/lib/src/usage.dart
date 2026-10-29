import 'dart:convert';
import 'dart:io';

/// Token use and estimated cost for one provider.
class ProviderUsage {
  final int calls;
  final int promptTokens;
  final int completionTokens;
  final double costUsd;

  /// Seconds of audio billed (Muse Voice Transcribe).
  final int audioSeconds;

  const ProviderUsage({
    this.calls = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costUsd = 0,
    this.audioSeconds = 0,
  });

  ProviderUsage add(
    int prompt,
    int completion,
    double cost, {
    int audioSeconds = 0,
  }) => ProviderUsage(
    calls: calls + 1,
    promptTokens: promptTokens + prompt,
    completionTokens: completionTokens + completion,
    costUsd: costUsd + cost,
    audioSeconds: this.audioSeconds + audioSeconds,
  );

  Map<String, Object?> toJson() => {
    'calls': calls,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'costUsd': costUsd,
    if (audioSeconds > 0) 'audioSeconds': audioSeconds,
  };

  static ProviderUsage fromJson(Map<String, Object?> json) => ProviderUsage(
    calls: (json['calls'] as num?)?.toInt() ?? 0,
    promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
    completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
    costUsd: (json['costUsd'] as num?)?.toDouble() ?? 0,
    audioSeconds: (json['audioSeconds'] as num?)?.toInt() ?? 0,
  );
}

/// Token use per provider, kept in `usage.json` in Doc's config directory.
class UsageStore {
  final File file;

  UsageStore(this.file);

  Map<String, ProviderUsage> read() {
    if (!file.existsSync()) return {};
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return {
      for (final entry in ((json['providers'] as Map?) ?? const {}).entries)
        entry.key as String: ProviderUsage.fromJson(
          (entry.value as Map).cast<String, Object?>(),
        ),
    };
  }

  ProviderUsage forProvider(String provider) =>
      read()[provider] ?? const ProviderUsage();

  void record(
    String provider,
    int prompt,
    int completion,
    double cost, {
    int audioSeconds = 0,
  }) {
    final usage = read();
    usage[provider] = (usage[provider] ?? const ProviderUsage()).add(
      prompt,
      completion,
      cost,
      audioSeconds: audioSeconds,
    );
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'providers': {for (final entry in usage.entries) entry.key: entry.value.toJson()},
      })}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }
}
