import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/voice/voice_session.dart';
import 'package:hamma/core/voice/voice_speaker.dart';

void main() {
  group('VoiceSession', () {
    test('starts off and not audio-active', () {
      final s = VoiceSession();
      expect(s.mode, VoiceMode.off);
      expect(s.audioActive, isFalse);
      expect(s.isVoiceEnabled, isFalse);
      expect(s.isConversational, isFalse);
    });

    test('mode transitions notify listeners and update derived flags', () {
      final s = VoiceSession();
      var notifications = 0;
      s.addListener(() => notifications++);

      s.setMode(VoiceMode.pushToTalk);
      expect(notifications, 1);
      expect(s.isVoiceEnabled, isTrue);
      expect(s.isConversational, isFalse);

      s.setMode(VoiceMode.conversational);
      expect(notifications, 2);
      expect(s.isConversational, isTrue);

      // Setting same mode is a no-op.
      s.setMode(VoiceMode.conversational);
      expect(notifications, 2);
    });

    test('audioActive flips notify only on change', () {
      final s = VoiceSession();
      var notifications = 0;
      s.addListener(() => notifications++);

      s.setAudioActive(true);
      s.setAudioActive(true);
      expect(notifications, 1);
      s.setAudioActive(false);
      expect(notifications, 2);
    });
  });

  group('VoiceSpeaker.sanitize', () {
    test('strips fenced code blocks', () {
      final out = VoiceSpeaker.sanitize(
        'Run this:\n```bash\nrm -rf /\n```\nDone.',
      );
      expect(out, contains('code block'));
      expect(out, isNot(contains('rm -rf')));
    });

    test('strips bold, italic, inline code, headings', () {
      final out = VoiceSpeaker.sanitize(
        '## Heading\n**bold** and *italic* with `code` inline.',
      );
      expect(out, 'Heading bold and italic with code inline.');
    });
  });
}
