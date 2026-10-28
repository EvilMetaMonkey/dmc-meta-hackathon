import 'dart:math';

import 'package:dmc_doc/src/bisect.dart';
import 'package:test/test.dart';

/// Points 0..[length]-1 where everything from [firstBad] on fails.
Future<BisectResult> search(int length, int firstBad) => bisectFirstBad(
  List.generate(length, (index) => index),
  (index, point) async => point < firstBad,
);

void main() {
  test('finds the first bad point in the middle, first and last', () async {
    for (final length in [2, 3, 6, 7, 16, 33]) {
      for (var firstBad = 1; firstBad < length; firstBad++) {
        final result = await search(length, firstBad);
        expect(result.status, BisectStatus.found, reason: '$length/$firstBad');
        expect(result.firstBad, firstBad, reason: '$length/$firstBad');
        expect(result.lastGood, firstBad - 1);
        final probed = result.probes.map((probe) => probe.index).toList();
        expect(probed.toSet(), hasLength(probed.length), reason: 'no repeats');
        expect(probed.take(2), [0, length - 1], reason: 'both ends first');
        // Both ends plus at most ceil(log2(n - 1)) search probes.
        final bound = 2 + (log(max(length - 1, 1)) / ln2).ceil();
        expect(result.probes.length, lessThanOrEqualTo(bound));
      }
    }
  });

  test('both ends are checked first', () async {
    final failsAtStart = await search(6, 0);
    expect(failsAtStart.status, BisectStatus.firstAlreadyFails);
    expect(failsAtStart.probes.map((probe) => probe.index), [0]);
    expect(failsAtStart.firstBad, isNull);

    final passesAtEnd = await search(6, 6);
    expect(passesAtEnd.status, BisectStatus.lastPasses);
    expect(passesAtEnd.probes.map((probe) => probe.index), [0, 5]);
  });

  test('needs a good end and a bad end', () {
    expect(
      () => bisectFirstBad([1], (index, point) async => true),
      throwsArgumentError,
    );
  });
}
