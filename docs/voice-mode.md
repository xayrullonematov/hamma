# Voice Mode (Mobile)

Hamma's AI Assistant supports hands-free operation on iOS and Android.
Voice is designed for the 3-a.m. on-call use case: pager fires, you grab
your phone, and talk to your fleet without typing on a glass keyboard.

## On-device guarantee

**No audio leaves the device.** Hamma will refuse to transcribe if it
cannot do so on-device.

| Platform | Recognizer                                     | Setting                                  |
|----------|-------------------------------------------------|------------------------------------------|
| iOS 13+  | `SFSpeechRecognizer`                            | `requiresOnDeviceRecognition = true`     |
| Android  | System `SpeechRecognizer`                       | `EXTRA_PREFER_OFFLINE = true`            |

If on-device recognition is unavailable (older iOS, Android without an
offline language pack installed) the mic button is **disabled** with a
tooltip explaining why. There is no silent cloud fallback on iOS — the
SFSpeechRecognizer hard-fails when `requiresOnDeviceRecognition` is set
and the locale isn't on-device, and Hamma surfaces that error.

> **Android caveat.** `EXTRA_PREFER_OFFLINE` is a *preference*, not an
> absolute hardware contract — a tiny minority of OEM recognizers may
> still fall back to a cloud service if no offline pack is installed.
> Hamma surfaces every plugin error verbatim, but you should verify
> your offline language pack is installed before relying on the
> on-device guarantee:
> Settings → System → Languages & input → On-device speech recognition.

The same applies to text-to-speech: iOS uses `AVSpeechSynthesizer`
(on-device by default), Android uses the system TTS engine — install
an offline voice pack via Settings → System → Languages & input → TTS.

## Modes

The voice toggle in the AI Assistant app bar cycles through three
states:

1. **Voice off** — typed input only. (Default.)
2. **Push to talk** — mic button visible. Hold to talk, release to send
   the transcript as if you typed it. Replies are shown but not spoken.
3. **Conversational** — mic + TTS. Assistant replies are spoken aloud
   automatically. You still tap the mic to reply (no auto-loop, to
   avoid feedback noise and battery drain).

## First-run disclosure

The first time you tap the mic, Hamma shows a one-time disclosure
explaining the on-device guarantee and the OS-level permission scope.
The OS will then prompt for microphone (and on iOS, speech-recognition)
permission. Acceptance is persisted in secure storage.

If you deny permission later via the OS settings the mic button stays
disabled with a tooltip — Hamma never re-prompts mid-session.

## Status indicator

While a voice session is active a tiny **🎤 ON-DEVICE** chip lights up
next to the local-engine status pill in the app bar. This is the same
visual contract the local-AI pill uses: the chip means "right now, no
audio is leaving this device."

## Pager wake (current behaviour)

Tap a Hamma push notification to land directly on the originating
server's AI Assistant. Set conversational mode once per server and the
mic + TTS path is one tap away from any wake.

> **Roadmap:** Native Android quick-settings tile, iOS Siri Shortcut,
> and a system share-intent that drops you straight into voice mode
> for a chosen server are tracked as a follow-up. The current build
> ships the core on-device voice loop; the wake-entry surfaces are
> additive and don't change the privacy model.

## Out of scope (v1)

- Wake-word activation ("Hey Hamma"). Battery + false-trigger risk too
  high; revisit only if a proven low-power on-device wake-word lib lands.
- Desktop voice support. Desktop has a real keyboard; the mic button
  doesn't render outside iOS/Android.
- Whisper.cpp / custom on-device ASR. The OS recognizers are good
  enough for v1 and avoid shipping another model.
- Voice in SFTP / Docker panels. AI Assistant only for v1.

## Troubleshooting

| Symptom                                        | Fix                                                                 |
|-----------------------------------------------|---------------------------------------------------------------------|
| Mic button greyed out on Android              | Settings → Apps → Google → Voice → install the offline language pack. |
| Mic button greyed out on iOS                  | Older iOS than 13, or device without on-device recognition support. |
| Replies aren't spoken in conversational mode  | Check the system TTS engine has a voice installed for your locale.  |
| Permission denied                             | iOS / Android Settings → Hamma → enable Microphone (and Speech).    |
