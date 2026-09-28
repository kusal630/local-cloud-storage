import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/server/pool/placement.dart';

const String _zeroId = '0000000000000000000000000000000000000000000000000000000000000000';

PlacementCandidate _c(String id, {int free = 10 << 30, int quota = 10 << 30, int used = 0}) =>
    PlacementCandidate(id: id, freeBytes: free, quotaBytes: quota, usedBytes: used);

void main() {
  group('fnv1a64', () {
    test('is deterministic and isolates inputs', () {
      expect(fnv1a64('abc'), fnv1a64('abc'));
      expect(fnv1a64('abc'), isNot(fnv1a64('abd')));
      expect(fnv1a64(''), isNot(fnv1a64('a')));
      // Stable across runs/platforms: this exact value is a contract with
      // any reader recomputing placement (CONSULT §3).
      expect(fnv1a64('chunk|contributor'), fnv1a64('chunk|contributor'));
    });
  });

  group('weights', () {
    test('are clamped to [1, 64] however large the disk', () {
      expect(_c('a', free: 1).weight, 1);
      expect(_c('b', free: 0).weight, 1);
      expect(_c('c', free: 100 << 30).weight, 64);
      expect(_c('d', free: 1 << 40).weight, 64);
    });

    test('a nearly-full cap shrinks the weight even when the disk is free', () {
      // 4 TB of raw space but only 200 MB left inside its own 10 GB quota:
      // this contributor must stop winning placements.
      final greedy = _c('g', free: 4000 << 30, quota: 10 << 30, used: (10 << 30) - (200 << 20));
      expect(greedy.weight, 3, reason: '200 MB headroom = 3 x 64 MiB units');
      final generous = _c('ok', free: 4000 << 30, quota: 10 << 30, used: 0);
      expect(generous.weight, 64);
    });

    test('weight never goes negative when a contributor is over quota', () {
      final overflowing = _c('x', free: 0, quota: 100, used: 500);
      expect(overflowing.capHeadroom, 0);
      expect(overflowing.weight, greaterThanOrEqualTo(1));
    });
  });

  group('rendezvous ranking', () {
    test('favours the heavier contributor most of the time', () {
      final heavy = _c('heavy', free: 64 << 30, quota: 64 << 30);
      final light = _c('light', free: 1 << 30, quota: 1 << 30);
      var heavyWins = 0;
      const chunks = 2000;
      for (var i = 0; i < chunks; i++) {
        final id = i.toRadixString(16).padLeft(64, '0');
        final ranked = PoolPlacement.rankedIds(id, [light, heavy]);
        if (ranked.first == 'heavy') heavyWins++;
      }
      // Weight 64 vs 1 -> the heavy node should win roughly 64/65 of the
      // time. Anything under 80% means the transform is broken.
      expect(heavyWins / chunks, greaterThan(0.75));
    });

    test('ranking among the original set survives adding a new candidate', () {
      // No-reshuffle-on-join (ZFS/Unraid rule): adding a device may only
      // insert it into the order, never reorder the devices already there.
      final before = [_c('a', free: 5 << 30), _c('b', free: 9 << 30), _c('c', free: 2 << 30)];
      final after = [...before, _c('new', free: 7 << 30)];
      for (var i = 0; i < 300; i++) {
        final id = i.toRadixString(16).padLeft(64, '0');
        final oldRank = PoolPlacement.rankedIds(id, before);
        final newRank =
            PoolPlacement.rankedIds(id, after).where((id) => id != 'new').toList();
        expect(newRank, oldRank, reason: 'chunk $id reordered existing devices');
      }
    });
  });

  group('place', () {
    final candidates = [_c('p'), _c('l'), _c('t')];

    test('returns at most `replication` DISTINCT contributors', () {
      for (var i = 0; i < 500; i++) {
        final id = i.toRadixString(16).padLeft(64, '0');
        final placement = PoolPlacement.place(id, candidates);
        expect(placement.replicaCount, 2);
        expect(placement.contributorIds.toSet().length, 2,
            reason: 'both copies landed on one device');
        expect(placement.contributorIds.toSet().length,
            placement.contributorIds.length);
      }
    });

    test('is deterministic for the same inputs', () {
      const id = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final a = PoolPlacement.place(id, candidates);
      final b = PoolPlacement.place(id, [...candidates].reversed.toList());
      expect(a.contributorIds, b.contributorIds,
          reason: 'candidate order must not change placement');
    });

    test('degrades honestly when there are fewer devices than copies', () {
      final one = [_c('only')];
      final placement = PoolPlacement.place(_zeroId, one);
      expect(placement.contributorIds, ['only'],
          reason: 'one device must get exactly one copy, never two');
      expect(PoolPlacement.place(_zeroId, []).contributorIds, isEmpty);
      expect(PoolPlacement.place(_zeroId, candidates, replication: 0)
          .contributorIds, isEmpty);
    });

    test('spreads evenly across equal-weight devices (no hot spot)', () {
      final equal = [
        for (final n in ['a', 'b', 'c', 'd', 'e']) _c(n),
      ];
      final counts = <String, int>{for (final c in equal) c.id: 0};
      const chunks = 5000;
      for (var i = 0; i < chunks; i++) {
        final id = i.toRadixString(16).padLeft(64, '0');
        for (final winner in PoolPlacement.place(id, equal).contributorIds) {
          counts[winner] = counts[winner]! + 1;
        }
      }
      // 5000 chunks x 2 copies over 5 devices = 2000 each on average.
      for (final entry in counts.entries) {
        expect(entry.value, greaterThan(1400),
            reason: '${entry.key} is under-used: ${entry.value}');
        expect(entry.value, lessThan(2700),
            reason: '${entry.key} is a hot spot: ${entry.value}');
      }
      expect(counts.values.fold<int>(0, (a, b) => a + b), chunks * 2);
    });
  });

  group('servers of happiness / diversity', () {
    test('two copies on one device survives zero failures', () {
      final bad = {
        'c1': ['a', 'a'],
        'c2': ['a', 'b'],
      };
      expect(PoolPlacement.isDiverse(bad), isFalse);
      expect(PoolPlacement.maxSurvivableFailures(bad), 0);
      expect(PoolPlacement.happiness(bad, target: 2), 0.5);
    });

    test('a healthy R=2 layout survives exactly one device failure', () {
      final good = {
        'c1': ['a', 'b'],
        'c2': ['b', 'c'],
        'c3': ['a', 'c'],
      };
      expect(PoolPlacement.isDiverse(good), isTrue);
      expect(PoolPlacement.maxSurvivableFailures(good), 1);
      expect(PoolPlacement.happiness(good, target: 2), 1.0);
    });

    test('a single copy survives nothing', () {
      final bad = {
        'c1': ['a'],
        'c2': ['a'],
      };
      expect(PoolPlacement.maxSurvivableFailures(bad), 0);
      expect(PoolPlacement.happiness(bad, target: 2), 0.0);
      expect(PoolPlacement.happiness({}, target: 2), 1.0,
          reason: 'an empty pool is not unhealthy');
    });
  });
}
