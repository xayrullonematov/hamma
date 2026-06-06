# Hamma Production-Readiness Audit & Remediation Roadmap

## 1. THE NATIVE FFI & PROCESS SIDE-CAR LAYER

**[lib/core/ai/llama_cpp_backend.dart]** -> Dead FFI stub class with zero actual native bindings, zero pointer lifecycle management, zero struct alignment definitions. Process.start() is illegal in iOS sandbox, making FFI the only path. -> 
```dart
// Required struct definitions for llama.cpp interop:
final class LlamaBatch extends Struct {
  @Int32() external int nTokens;
  external Pointer<Int32> token;
  external Pointer<Float> embd;
  external Pointer<Int32> pos;
  external Pointer<Int32> nSeqId;
  external Pointer<Pointer<Int32>> seqId;
  external Pointer<Int8> logits;
}

class LlamaCppBackend implements InferenceBackend {
  Pointer<Void>? _modelPtr;
  Pointer<Void>? _ctxPtr;
  final _allocations = <Pointer>[];
  bool _disposed = false;
  
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ctxPtr != null) _bindings.llama_free(_ctxPtr!);
    if (_modelPtr != null) _bindings.llama_free_model(_modelPtr!);
    for (final ptr in _allocations.reversed) calloc.free(ptr);
    _allocations.clear();
  }
}
```

**[lib/core/ai/llama_server_backend.dart]** -> StreamSubscription leak: stdout/stderr listeners are never cancelled; no SIGTERM→SIGKILL escalation on process shutdown -> 
```dart
StreamSubscription? _stdoutSub;
StreamSubscription? _stderrSub;

Future<void> start() async {
  _stdoutSub = _process!.stdout.transform(utf8.decoder).listen(_onStdout);
  _stderrSub = _process!.stderr.transform(utf8.decoder).listen(_onStderr);
}

@override
Future<void> dispose() async {
  await _stdoutSub?.cancel();
  await _stderrSub?.cancel();
  _httpClient.close();
  _process?.kill(ProcessSignal.sigterm);
  await _process?.exitCode.timeout(Duration(seconds: 5), onTimeout: () {
    _process?.kill(ProcessSignal.sigkill);
    return -1;
  });
}
```

**[lib/core/ai/llama_server_backend.dart]** -> No Platform.isIOS guard on subprocess-based backend -> 
```dart
factory LlamaServerBackend.create() {
  if (Platform.isIOS) {
    throw UnsupportedError('LlamaServerBackend requires subprocess spawning, prohibited in iOS sandbox. Use LlamaCppBackend (FFI) instead.');
  }
  return LlamaServerBackend._();
}
```

**[lib/core/ai/inference_engine.dart]** -> No inference request serialization causes parallel HTTP requests to single-threaded llama-server or concurrent C calls to non-thread-safe llama.cpp ->
```dart
final _inferenceLock = Lock(); // from package:synchronized

Future<String> generate(String prompt) async {
  return _inferenceLock.synchronized(() async {
    return _activeBackend.generate(prompt);
  });
}
```

**[lib/core/ai/]** -> Main isolate inference blocks UI event loop during FFI synchronous calls or HTTP microtasks -> 
```dart
class IsolatedInferenceEngine {
  late final SendPort _sendPort;
  
  Future<void> init() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_inferenceIsolateEntry, receivePort.sendPort);
    _sendPort = await receivePort.first as SendPort;
  }
  
  static void _inferenceIsolateEntry(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);
    final backend = LlamaCppBackend();
    receivePort.listen((message) { /* Handle inference requests */ });
  }
}
```

## 2. SYSTEM LOG TRIAGE & LOG ANALYSIS FLOODS

**[lib/core/ai/command_risk_assessor.dart]** -> assessFast trivially bypassed by backslash prefix (`\rm`), flag splitting (`rm -r -f`), base64 execution, path prefixes (`/bin/rm`); missing unknown risk level ->
```dart
enum RiskLevel { low, medium, high, critical, unknown }

class CommandRiskAssessor {
  static String _normalize(String command) {
    return command.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }
  
  static RiskLevel assessFast(String command) {
    final normalized = _normalize(command);
    final tokens = normalized.split(' ');
    
    if (_containsMetaExecution(normalized)) return RiskLevel.critical;
    
    if (tokens.contains('rm') && (tokens.contains('-rf') || tokens.contains('-fr') || 
        (tokens.contains('-r') && tokens.contains('-f')))) {
      return RiskLevel.critical;
    }
    
    return RiskLevel.unknown;
  }
  
  static bool _containsMetaExecution(String cmd) {
    return cmd.contains('eval ') || cmd.contains('| bash') || cmd.contains('| sh') ||
           cmd.contains('base64 -d') || cmd.contains(r'$(' ) || cmd.contains('`');
  }
}
```

**[lib/core/ai/ai_command_service.dart]** -> parseJsonFromResponse brace-depth scanner has no input length cap, leading to CPU/Memory exhaustion and allocations on crafted nested structures -> 
```dart
static Map<String, dynamic>? parseJsonFromResponse(String text) {
  const maxResponseLen = 65536;
  final trimmed = text.length > maxResponseLen
      ? text.substring(0, maxResponseLen).trim()
      : text.trim();
  // Proceed with extraction
}
```

**[lib/core/ai/log_triage/log_triage_service.dart]** -> Unbounded string concatenation creates prompt payloads up to ~1MB causing LLM KV cache exhaustion/truncation ->
```dart
String _buildPrompt(LogBatch batch) {
  const maxPromptLines = 100;
  const maxLineLen = 2000;
  final buf = StringBuffer();
  final linesToSend = batch.lines.take(maxPromptLines);
  for (final line in linesToSend) {
    buf.writeln(line.length > maxLineLen ? '${line.substring(0, maxLineLen)}…[truncated]' : line);
  }
  return buf.toString();
}
```

**[lib/core/ai/ai_command_service.dart]** -> `_chatWithOpenAi` reads unbounded HTTP response into memory via `.join()` ->
```dart
const maxResponseBytes = 65536;
var totalBytes = 0;
final responseBody = await response
    .transform(utf8.decoder)
    .takeWhile((chunk) {
      totalBytes += chunk.length;
      return totalBytes <= maxResponseBytes;
    })
    .join();
```

**[lib/core/ai/log_triage/log_batcher.dart]** -> No total buffer byte cap on log ingestion, only line count, enabling memory exhaustion with pathologically large lines ->
```dart
int _bufferBytes = 0;
const maxBufferBytes = 512 * 1024;
// In the listener:
_bufferBytes += line.length;
buffer.add(line);
if (buffer.length >= cap || _bufferBytes >= maxBufferBytes) flush();
```

**[lib/core/ai/log_triage/log_triage_models.dart]** -> LLM prompt injection enables `assessFast` bypass allowing one-tap execution of malicious commands ->
```dart
// Introduce strong prompt delimiters and structural instructions
final prompt = '''<UNTRUSTED_LOGS>
$sanitizedBatch
</UNTRUSTED_LOGS>''';

// Add secondary heuristic gate in service rejecting any piped evaluators or interpreters from suggested commands
```

## 3. TRUST BOUNDARIES & SUPPLY CHAIN INTEGRITY

**[lib/core/ai/loopback_guard.dart]** -> Hostname string comparison without DNS resolution enables DNS rebinding bypass; TOCTOU race condition -> 
```dart
class LoopbackGuard {
  static Future<InternetAddress> resolveAndValidate(String url) async {
    final uri = Uri.parse(url);
    final addresses = await InternetAddress.lookup(uri.host);
    
    if (!addresses.every((addr) => addr.isLoopback)) {
      throw SecurityException('Host ${uri.host} resolved to non-loopback address');
    }
    return addresses.first;
  }
}
// In OllamaClient:
final validatedAddr = await LoopbackGuard.resolveAndValidate(baseUrl);
final response = await http.get(Uri.parse(url).replace(host: validatedAddr.address));
```

**[lib/features/local/bundled_model_downloader.dart]** -> Downloaded GGUF model files have zero cryptographic integrity verification; non-atomic file write allows corrupt partial model loads ->
```dart
Future<File> downloadModel(BundledModelEntry entry) async {
  final tempFile = File('${entry.targetPath}.download');
  final targetFile = File(entry.targetPath);
  
  final request = http.Request('GET', Uri.parse(entry.downloadUrl));
  final response = await _client.send(request);
  
  final sink = tempFile.openWrite();
  final digestSink = AccumulatorSink<Digest>();
  final hashSink = sha256.startChunkedConversion(digestSink);
  
  int bytesReceived = 0;
  await for (final chunk in response.stream) {
    sink.add(chunk);
    hashSink.add(chunk);
    bytesReceived += chunk.length;
    if (bytesReceived > entry.maxSizeBytes) throw Exception('Size limit exceeded');
  }
  
  await sink.close();
  hashSink.close();
  
  final computedHash = digestSink.events.single.toString();
  if (computedHash != entry.sha256Hash) throw Exception('Hash mismatch');
  
  await tempFile.rename(targetFile.path);
  return targetFile;
}
```

**[lib/features/local/bundled_model_catalog.dart]** -> Model catalog entries lack cryptographic hash and max size fields ->
```dart
class BundledModelEntry {
  final String modelName;
  final String downloadUrl;
  final int fileSizeBytes;
  final int maxSizeBytes;
  final String sha256Hash;
}
```

## 4. SYSTEMD, TERMINAL & POSIX SHELL ESCAPING

**[lib/features/docker/docker_screen.dart]** -> Unescaped remote-derived container IDs and user-provided image names spliced directly into shell commands ->
```dart
String shellEscape(String input) {
  return "'${input.replaceAll("'", "'\\''")}'";
}
ssh.execute('docker logs --tail 100 ${shellEscape(containerId)}');
ssh.execute('docker pull ${shellEscape(imageName)}');
```

**[lib/features/services/services_screen.dart]** -> Remote-derived service names from systemctl output spliced into sudo-elevated shell commands without escaping ->
```dart
final validServiceName = RegExp(r'^[a-zA-Z0-9@._\-]+$');
if (!validServiceName.hasMatch(serviceName)) throw ArgumentError('Invalid service name');
ssh.execute('sudo systemctl restart ${shellEscape(serviceName)}');
```

**[lib/features/processes/process_screen.dart]** -> PID values from remote ps output used in kill commands without numeric validation ->
```dart
final numericPid = int.tryParse(pid);
if (numericPid == null || numericPid <= 0) throw ArgumentError('Invalid PID');
ssh.execute('kill ${numericPid.toString()}');
```

**[lib/features/quick_actions/quick_actions_screen.dart]** -> User-provided package names and file paths spliced into privileged shell commands ->
```dart
final validPkgName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.+\-]+$');
if (!validPkgName.hasMatch(packageName)) throw ArgumentError('Invalid package name');
ssh.execute('cat ${shellEscape(filePath)}');
```

**[lib/features/observability/health_tab.dart]** -> Parsed /proc/net/dev interface names and df mount points used in subsequent commands without escaping ->
```dart
final validInterfaceName = RegExp(r'^[a-zA-Z0-9._\-]+$');
if (!validInterfaceName.hasMatch(interfaceName)) throw ArgumentError('Invalid interface');
```

## 5. CONCURRENCY, SYNCHRONIZATION BUSES & DATA SAFETY

**[lib/core/sync/cloud_sync_engine.dart]** -> Last-write-wins with device-local timestamps causes silent data loss under concurrent edits and clock skew; no mutex/lock on concurrent sync invocations ->
```dart
class CloudSyncEngine {
  final _syncLock = Completer<void>();
  bool _syncing = false;
  bool _pendingSync = false;
  
  Future<void> sync() async {
    if (_syncing) {
      _pendingSync = true;
      return;
    }
    _syncing = true;
    try {
      await _performSync();
    } finally {
      _syncing = false;
      if (_pendingSync) {
        _pendingSync = false;
        Future.microtask(() => sync());
      }
    }
  }
}
```

**[lib/core/sync/snippet_sync_service.dart]** -> No tombstone records for deletions; deleted items reappear from remote ->
```dart
class SnippetTombstone {
  final String snippetId;
  final DateTime deletedAt;
  final String deletedByDeviceId;
}

class SnippetSyncService {
  final List<SnippetTombstone> _tombstones = [];
  void deleteSnippet(String id) {
    _snippets.removeWhere((s) => s.id == id);
    _tombstones.add(SnippetTombstone(snippetId: id, deletedAt: DateTime.now().toUtc(), deletedByDeviceId: _deviceId));
  }
}
```

**[lib/core/sync/vault_sync_service.dart]** -> Last-write-wins on encrypted vault entries enables cryptographic rollback to older key versions; decrypted credentials linger in Dart heap after sync merge ->
```dart
VaultEntry resolveConflict(VaultEntry local, VaultEntry remote) {
  if (local.keyVersion != remote.keyVersion) {
    return local.keyVersion > remote.keyVersion ? local : remote;
  }
  return local.updatedAt.isAfter(remote.updatedAt) ? local : remote;
}

void _zeroFill(Uint8List data) {
  for (int i = 0; i < data.length; i++) data[i] = 0;
}
```

## 6. COMPLIANCE & REFACTORING FOOTPRINT

**[analysis_options.yaml]** -> Three production-critical lint rules (`cancel_subscriptions`, `close_sinks`, `unawaited_futures`) are silenced to `ignore`, missing `strict-casts` and `strict-raw-types` ->
```yaml
analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
    strict-inference: true
# Remove cancel_subscriptions, close_sinks, unawaited_futures from 'errors: ignore' block
```

**[lib/features/ai_assistant/ai_assistant_screen.dart]** -> `jsonDecode` returns `dynamic`, downstream map access has no type guards ->
```dart
final decoded = jsonDecode(responseBody);
if (decoded is! Map<String, dynamic>) throw FormatException('Expected JSON object');
final choices = decoded['choices'];
if (choices is! List || choices.isEmpty) throw FormatException('Missing choices');
```

**[lib/features/ai_assistant/ai_copilot_sheet.dart]** -> setState() called after dispose() in async AI response handler; StreamSubscription lifecycle not guaranteed to be cleaned up ->
```dart
Future<void> _sendToAi() async {
  try {
    final result = await _aiService.generateCommand(prompt);
    if (!mounted) return;
    setState(() { _response = result; });
  } catch (e) {
    if (!mounted) return;
    setState(() { _error = e.toString(); });
  }
}
```

**[lib/features/settings/settings_screen.dart]** -> API keys displayed in plaintext TextField and held in uncleared heap memory; no format validation before storage ->
```dart
void _saveApiKey(String provider, String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'[\n\r\x00-\x1f]'))) {
    _showError('Invalid API key format');
    return;
  }
  _storage.saveApiKey(provider, trimmed);
}
// Clear in dispose: _apiKeyController.clear(); _apiKeyController.dispose();
```

**[lib/main.dart]** -> 38KB god file with interleaved concerns (routing, state, theme, platform logic) ->
```text
Extract into: lib/app.dart (root widget), lib/router.dart (navigation), lib/di.dart (dependency injection), lib/core/theme/theme.dart.
```

---

## REMEDIATION ROADMAP

### Phase 1: Critical Security & Injection Vectors (Immediate)
1. **Global Shell Escaping:** Introduce `shellEscape()` utility and apply it project-wide to all `ssh.execute()` calls involving remote-derived or user-provided inputs (`docker_screen.dart`, `services_screen.dart`, `process_screen.dart`, `health_tab.dart`).
2. **Command Risk Assessor Strengthening:** Overhaul `CommandRiskAssessor.assessFast()` to use tokenizer-based pattern matching instead of substring matching, normalizing whitespace and recognizing shell meta-execution (`eval`, `base64`, `sh`). Introduce `RiskLevel.unknown`.
3. **Supply Chain Integrity:** Update `BundledModelDownloader` to verify SHA-256 hashes of all downloaded `.gguf` weights before atomic rename to prevent model poisoning/RCE via parsing bugs.
4. **Trust Boundary Hardening:** Fix `LoopbackGuard` to perform actual DNS resolution (preventing DNS rebinding) and enforce TOCTOU protection by connecting directly to the resolved loopback IP.

### Phase 2: High Reliability & Resource Safety (Short-term)
1. **Memory Exhaustion Protections:** Add hard byte caps to `LogBatcher` and HTTP `.join()` transformations in `ai_command_service.dart`. Add input caps to regex parsing to prevent ReDoS/wedging.
2. **Process Lifecycle Leaks:** Address zombie processes in `LlamaServerBackend` by implementing proper `SIGTERM` to `SIGKILL` escalation and cancelling all `stdout`/`stderr` stream subscriptions on `dispose()`.
3. **Sync Engine Safety:** Introduce mutex locks to `CloudSyncEngine` to prevent read-modify-write races. Implement tombstone records in `SnippetSyncService` to prevent deleted items from resurrecting. Add key version checks to `VaultSyncService` to prevent cryptographic rollback.

### Phase 3: Architecture, Compliance & Tech Debt (Medium-term)
1. **FFI iOS Compliance:** Establish actual `dart:ffi` bindings in `LlamaCppBackend` utilizing `Isolate` architecture to bypass the iOS sandbox process-spawning ban and prevent main-thread UI freezing.
2. **Static Analysis Strictness:** Un-ignore `cancel_subscriptions`, `close_sinks`, and `unawaited_futures` in `analysis_options.yaml`. Enable `strict-casts` and `strict-raw-types`.
3. **Refactoring:** Decompose the 38KB `main.dart` into specialized files (`app.dart`, `router.dart`, `di.dart`) for maintainability. Implement proper type guarding over `jsonDecode()` returns in AI parsing layers.
