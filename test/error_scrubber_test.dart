import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/error/error_scrubber.dart';

void main() {
  group('ErrorScrubber.scrub — null & empty input', () {
    test('returns empty string for null input', () {
      expect(ErrorScrubber.scrub(null), '');
    });

    test('returns empty string for empty input', () {
      expect(ErrorScrubber.scrub(''), '');
    });

    test('returns input unchanged when no sensitive data is present', () {
      const input = 'SocketException: Connection refused on host 10.0.0.5';
      expect(ErrorScrubber.scrub(input), input);
    });
  });

  group('ErrorScrubber.scrub — field=value patterns', () {
    test('scrubs password=...', () {
      final result = ErrorScrubber.scrub('Login failed for password=hunter2');
      expect(result, 'Login failed for password=[SCRUBBED]');
    });

    test('scrubs password: ... (colon, with space)', () {
      final result = ErrorScrubber.scrub('Config: password: hunter2');
      expect(result, 'Config: password: [SCRUBBED]');
    });

    test('scrubs quoted password values', () {
      final result = ErrorScrubber.scrub('password="hunter2 with spaces"');
      expect(result, 'password=[SCRUBBED]');
    });

    test('scrubs single-quoted password values', () {
      final result = ErrorScrubber.scrub("password='hunter2'");
      expect(result, 'password=[SCRUBBED]');
    });

    test('scrubs pin=...', () {
      expect(ErrorScrubber.scrub('pin=1234'), 'pin=[SCRUBBED]');
    });

    test('scrubs token=...', () {
      expect(ErrorScrubber.scrub('token=abc.def.ghi'), 'token=[SCRUBBED]');
    });

    test('scrubs apiKey=...', () {
      expect(ErrorScrubber.scrub('apiKey=xyz789'), 'apiKey=[SCRUBBED]');
    });

    test('scrubs api_key=... (snake case)', () {
      expect(ErrorScrubber.scrub('api_key=xyz789'), 'api_key=[SCRUBBED]');
    });

    test('scrubs api-key=... (kebab case)', () {
      expect(ErrorScrubber.scrub('api-key=xyz789'), 'api-key=[SCRUBBED]');
    });

    test('scrubs secret=...', () {
      expect(ErrorScrubber.scrub('secret=topsecret'), 'secret=[SCRUBBED]');
    });

    test('is case-insensitive', () {
      expect(ErrorScrubber.scrub('PASSWORD=Foo'), 'PASSWORD=[SCRUBBED]');
      expect(ErrorScrubber.scrub('Token=Bar'), 'Token=[SCRUBBED]');
    });

    test('scrubs multiple fields in one message', () {
      final result = ErrorScrubber.scrub(
        'Error connecting with password=foo and token=bar',
      );
      expect(
        result,
        'Error connecting with password=[SCRUBBED] and token=[SCRUBBED]',
      );
    });
  });

  group('ErrorScrubber.scrub — Authorization headers', () {
    test('scrubs Bearer tokens', () {
      final result = ErrorScrubber.scrub(
        'HTTP 401: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9',
      );
      expect(
        result,
        'HTTP 401: Authorization: Bearer [SCRUBBED]',
      );
    });

    test('scrubs Basic auth headers', () {
      final result = ErrorScrubber.scrub(
        'HTTP 401: Authorization: Basic dXNlcjpwYXNz',
      );
      expect(
        result,
        'HTTP 401: Authorization: Basic [SCRUBBED]',
      );
    });

    test('preserves the auth scheme name (Bearer/Basic)', () {
      // The scheme is useful debugging info — only the credential is
      // sensitive.
      expect(
        ErrorScrubber.scrub('Bearer abcdefghijklmnopqrst'),
        'Bearer [SCRUBBED]',
      );
      expect(
        ErrorScrubber.scrub('Basic dXNlcjpwYXNzd29yZA=='),
        'Basic [SCRUBBED]',
      );
    });

    test('does not scrub short tokens that are likely not credentials', () {
      // 7 chars after Bearer — below the 8-char threshold, so left alone.
      expect(ErrorScrubber.scrub('Bearer abcdefg'), 'Bearer abcdefg');
    });
  });

  group('ErrorScrubber.scrub — OpenAI-style sk- keys', () {
    test('scrubs an OpenAI-style API key', () {
      final result = ErrorScrubber.scrub(
        'OpenAI returned 401 for key sk-abc123def456ghi789jkl012mno345',
      );
      expect(
        result,
        'OpenAI returned 401 for key sk-[SCRUBBED]',
      );
    });

    test('does not scrub bare "sk-" prefix without the key body', () {
      expect(ErrorScrubber.scrub('sk-short'), 'sk-short');
    });

    test('scrubs sk- keys with dashes and underscores', () {
      final result =
          ErrorScrubber.scrub('Got sk-abcd_1234-efgh_5678-ijkl_9012 from API');
      expect(result, contains('sk-[SCRUBBED]'));
      expect(result, isNot(contains('abcd_1234')));
    });
  });

  group('ErrorScrubber.scrub — standalone JWTs', () {
    test('scrubs a JWT not wrapped in a Bearer header', () {
      // Realistic JWT shape: header.payload.signature, all base64url.
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
          'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.'
          'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      final result = ErrorScrubber.scrub('Decoded $jwt successfully');
      expect(result, 'Decoded [SCRUBBED JWT] successfully');
      expect(result, isNot(contains('eyJhbGc')));
    });

    test('scrubs a JWT inside a stack-trace-style line', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoidGVzdCJ9.signaturepart12345';
      final result = ErrorScrubber.scrub(
        '#0 AuthService._validate (file:///lib/auth.dart:42:5) token=$jwt',
      );
      // The field-pair `token=` rule fires first; either way the JWT
      // body must not survive.
      expect(result, contains('[SCRUBBED'));
      expect(result, isNot(contains('eyJ1c2VyIjoidGVzdCJ9')));
    });

    test('does not match a single base64-ish segment (not a JWT)', () {
      // Only one segment, no dots — must not be treated as a JWT.
      const notJwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';
      expect(ErrorScrubber.scrub(notJwt), notJwt);
    });

    test('does not match two segments (not a JWT — no signature)', () {
      const notJwt = 'eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoidGVzdCJ9';
      expect(ErrorScrubber.scrub(notJwt), notJwt);
    });
  });

  group('ErrorScrubber.scrub — PEM private key blocks', () {
    test('scrubs an RSA private key block', () {
      const pem =
          '-----BEGIN RSA PRIVATE KEY-----\n'
          'MIIEowIBAAKCAQEAvXz...\n'
          'multiple lines of base64\n'
          '-----END RSA PRIVATE KEY-----';
      final result = ErrorScrubber.scrub('Failed to parse: $pem');
      expect(result, 'Failed to parse: [SCRUBBED PRIVATE KEY]');
      expect(result, isNot(contains('MIIEow')));
    });

    test('scrubs an OPENSSH private key block', () {
      const pem =
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'b3BlbnNzaC1rZXktdjE\n'
          '-----END OPENSSH PRIVATE KEY-----';
      final result = ErrorScrubber.scrub(pem);
      expect(result, '[SCRUBBED PRIVATE KEY]');
    });

    test('scrubs a generic PRIVATE KEY block (no algorithm name)', () {
      const pem =
          '-----BEGIN PRIVATE KEY-----\n'
          'MIIEvQIBADAN\n'
          '-----END PRIVATE KEY-----';
      final result = ErrorScrubber.scrub(pem);
      expect(result, '[SCRUBBED PRIVATE KEY]');
    });

    test('preserves surrounding context around a PEM block', () {
      const pem =
          '-----BEGIN RSA PRIVATE KEY-----\nABC\n-----END RSA PRIVATE KEY-----';
      final result = ErrorScrubber.scrub('Before $pem after');
      expect(result, 'Before [SCRUBBED PRIVATE KEY] after');
    });
  });

  group('ErrorScrubber.scrub — non-greedy & no over-scrub', () {
    test('does not scrub the field name "key" appearing alone', () {
      // The word "key" by itself is not sensitive. Only `apiKey=`,
      // `api_key=`, `api-key=`, `private_key=`, etc. are.
      expect(
        ErrorScrubber.scrub('Map key not found: serverHost'),
        'Map key not found: serverHost',
      );
    });

    test('does not scrub a bare "password" word with no value', () {
      expect(
        ErrorScrubber.scrub('Password authentication failed'),
        'Password authentication failed',
      );
    });

    test('does not scrub URLs that contain the literal word "key"', () {
      const url = 'https://api.example.com/v1/users/keychain';
      expect(ErrorScrubber.scrub(url), url);
    });

    test('handles multiple distinct PEM blocks', () {
      const input = '''
-----BEGIN RSA PRIVATE KEY-----
KEY1
-----END RSA PRIVATE KEY-----
some text
-----BEGIN OPENSSH PRIVATE KEY-----
KEY2
-----END OPENSSH PRIVATE KEY-----
''';
      final result = ErrorScrubber.scrub(input);
      expect(result, isNot(contains('KEY1')));
      expect(result, isNot(contains('KEY2')));
      expect(result, contains('some text'));
    });
  });

  group('ErrorScrubber.scrub — robustness', () {
    test('does not throw on extremely long input', () {
      final huge = 'a' * 100000;
      expect(() => ErrorScrubber.scrub(huge), returnsNormally);
    });

    test('does not throw on input with control characters', () {
      expect(
        () => ErrorScrubber.scrub('error\x00with\x01nulls\x07and\x1bescapes'),
        returnsNormally,
      );
    });

    test('preserves stack-trace-like multi-line input', () {
      const stack =
          'Exception: failed\n'
          '#0      main.<anonymous closure> (file:///lib/main.dart:42:5)\n'
          '#1      _rootRunUnary (dart:async/zone.dart:1407:47)';
      expect(ErrorScrubber.scrub(stack), stack);
    });
  });
}
