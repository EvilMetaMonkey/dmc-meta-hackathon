/// How a bisect search ended.
enum BisectStatus {
  /// The first point passes, the last fails, and [BisectResult.firstBad] is
  /// the first failing point.
  found,

  /// The first point (the good end) already fails.
  firstAlreadyFails,

  /// The last point passes: nothing to find.
  lastPasses,
}

/// One probe the search ran.
class BisectProbe {
  final int index;
  final bool passed;

  const BisectProbe(this.index, this.passed);
}

class BisectResult {
  final BisectStatus status;

  /// The first failing point; null unless [status] is found.
  final int? firstBad;

  /// The last passing point before it; null unless [status] is found.
  final int? lastGood;

  /// Every probe, in the order it ran.
  final List<BisectProbe> probes;

  const BisectResult(
    this.status, {
    this.firstBad,
    this.lastGood,
    required this.probes,
  });
}

/// Find the first failing point in [points], ordered from the expected
/// good end to the expected bad end. Both ends are checked first: the first
/// point must pass and the last must fail. Then a binary search assumes
/// everything after the first failing point fails, so it needs about
/// log2(n) probes beyond the two ends. [passes] runs one probe; the search
/// never probes a point twice.
Future<BisectResult> bisectFirstBad<T>(
  List<T> points,
  Future<bool> Function(int index, T point) passes,
) async {
  if (points.length < 2) {
    throw ArgumentError('Bisect needs at least a good end and a bad end.');
  }
  final probes = <BisectProbe>[];
  Future<bool> probe(int index) async {
    final passed = await passes(index, points[index]);
    probes.add(BisectProbe(index, passed));
    return passed;
  }

  if (!await probe(0)) {
    return BisectResult(BisectStatus.firstAlreadyFails, probes: probes);
  }
  final last = points.length - 1;
  if (await probe(last)) {
    return BisectResult(BisectStatus.lastPasses, probes: probes);
  }
  var good = 0;
  var bad = last;
  while (bad - good > 1) {
    final middle = good + (bad - good) ~/ 2;
    if (await probe(middle)) {
      good = middle;
    } else {
      bad = middle;
    }
  }
  return BisectResult(
    BisectStatus.found,
    firstBad: bad,
    lastGood: good,
    probes: probes,
  );
}
