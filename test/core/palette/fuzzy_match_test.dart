import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/palette/fuzzy_match.dart';

void main() {
  group('fuzzyScore', () {
    test('returns 1.0 for empty input', () {
      expect(fuzzyScore('', 'target'), equals(1.0));
      expect(fuzzyScore('', ''), equals(1.0));
    });

    test('returns 0.0 for empty target and non-empty input', () {
      expect(fuzzyScore('input', ''), equals(0.0));
    });

    test('returns 1.0 for exact match (case-insensitive)', () {
      expect(fuzzyScore('target', 'target'), equals(1.0));
      expect(fuzzyScore('TARGET', 'target'), equals(1.0));
      expect(fuzzyScore('TaRgEt', 'tArGeT'), equals(1.0));
    });

    test('returns 0.9 for prefix match', () {
      expect(fuzzyScore('tar', 'target'), equals(0.9));
      expect(fuzzyScore('TAR', 'target'), equals(0.9));
    });

    test('returns 0.7 for substring match', () {
      expect(fuzzyScore('arg', 'target'), equals(0.7));
      expect(fuzzyScore('get', 'target'), equals(0.7));
      expect(fuzzyScore('ARG', 'target'), equals(0.7));
    });

    test('returns correctly scaled score for subsequence match', () {
      // "tgt" in "target", length 3 in 6 -> density 0.5
      // Expected: 0.3 + 0.5 * 0.3 = 0.45
      expect(fuzzyScore('tgt', 'target'), closeTo(0.45, 0.001));

      // "trgt" in "target", length 4 in 6 -> density 0.666...
      // Expected: 0.3 + 0.666... * 0.3 = 0.5
      expect(fuzzyScore('trgt', 'target'), closeTo(0.5, 0.001));

      expect(fuzzyScore('TGT', 'target'), closeTo(0.45, 0.001));
    });

    test('returns 0.0 for no match', () {
      expect(fuzzyScore('z', 'target'), equals(0.0));
      expect(fuzzyScore('tarz', 'target'), equals(0.0));
      expect(fuzzyScore('tgtz', 'target'), equals(0.0));
    });
  });

  group('fuzzyBestScore', () {
    test('returns 0.0 for empty candidates', () {
      expect(fuzzyBestScore('input', []), equals(0.0));
    });

    test('returns best score among candidates', () {
      final candidates = ['foo', 'bar', 'target'];
      // 'tar' matches 'target' as prefix (0.9), no match for 'foo' or 'bar'
      expect(fuzzyBestScore('tar', candidates), equals(0.9));

      // 'r' matches 'bar' and 'target' as substring (0.7), no match for 'foo'
      expect(fuzzyBestScore('r', candidates), equals(0.7));

      // 'o' matches 'foo' as substring (0.7)
      expect(fuzzyBestScore('o', candidates), equals(0.7));

      // 'z' matches nothing (0.0)
      expect(fuzzyBestScore('z', candidates), equals(0.0));
    });

    test('returns 1.0 immediately on exact match', () {
      final candidates = ['foo', 'target', 'tar'];
      // 'target' matches 'target' exactly (1.0)
      expect(fuzzyBestScore('target', candidates), equals(1.0));
    });
  });

  group('score', () {
    test('scales exact match to 100', () {
      expect(score('target', 'target'), equals(100));
    });

    test('scales prefix match to 90', () {
      expect(score('tar', 'target'), equals(90));
    });

    test('scales substring match to 70', () {
      expect(score('arg', 'target'), equals(70));
    });

    test('scales subsequence match appropriately', () {
      expect(score('tgt', 'target'), equals(45));
    });

    test('returns 0 for no match', () {
      expect(score('z', 'target'), equals(0));
    });
  });
}
