import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/palette/fuzzy_match.dart';

void main() {
  group('fuzzyScore', () {
    test('empty input matches everything', () {
      expect(fuzzyScore('', 'anything'), 1.0);
    });

    test('exact match scores 1.0', () {
      expect(fuzzyScore('prod', 'prod'), 1.0);
    });

    test('prefix match scores 0.9', () {
      expect(fuzzyScore('prod', 'production-db'), 0.9);
    });

    test('substring match scores 0.7', () {
      expect(fuzzyScore('db', 'production-db'), 0.7);
    });

    test('subsequence match scores in [0.3, 0.6]', () {
      // p_d_b in production-db
      final s = fuzzyScore('pdb', 'production-db');
      expect(s, greaterThan(0));
      expect(s, lessThanOrEqualTo(0.6));
    });

    test('non-match scores 0', () {
      expect(fuzzyScore('xyz', 'production-db'), 0);
    });

    test('case-insensitive', () {
      expect(fuzzyScore('PROD', 'production-db'), 0.9);
    });

    test('ranking: exact > prefix > substring > subsequence', () {
      // exact "prod" beats prefix "production-db"
      expect(
        fuzzyScore('prod', 'prod'),
        greaterThan(fuzzyScore('prod', 'production-db')),
      );
      // prefix "production-db" beats interior-substring "a-prod-thing"
      expect(
        fuzzyScore('prod', 'production-db'),
        greaterThan(fuzzyScore('prod', 'a-prod-thing')),
      );
      // substring beats subsequence (input "pdb" → substring in "a-pdb-host"
      // but only a subsequence in "p_r_o_d_b_y")
      expect(
        fuzzyScore('pdb', 'a-pdb-host'),
        greaterThan(fuzzyScore('pdb', 'porpoise-bay-yard')),
      );
    });
  });

  group('fuzzyBestScore', () {
    test('returns the best across candidates', () {
      final s = fuzzyBestScore('db', ['prod-server', 'prod-db']);
      expect(s, 0.7); // substring on second candidate
    });

    test('short-circuits on 1.0', () {
      final s = fuzzyBestScore('prod', ['prod', 'unrelated']);
      expect(s, 1.0);
    });
  });
}
