import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'cloud_sync_adapter.dart';

/// AWS-compatible object storage adapter — works with AWS S3, Cloudflare R2,
/// Backblaze B2 (S3 endpoint), MinIO, Wasabi, and any other provider that
/// speaks SigV4. Authentication uses access-key / secret pairs the user
/// configures in settings; no credentials ever leave the device beyond
/// the standard AWS Authorization header.
///
/// Zero-trust guarantee: this adapter is only ever called with bytes that
/// have already been encrypted by `BackupCrypto`. It never inspects, logs
/// or transforms the payload — it just signs the HTTPS PUT/GET.
class S3CompatAdapter implements CloudSyncAdapter {
  S3CompatAdapter({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.prefix = 'hamma/',
    this.usePathStyle = false,
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  /// e.g. `https://s3.amazonaws.com`, `https://<accountid>.r2.cloudflarestorage.com`,
  /// `https://s3.us-west-002.backblazeb2.com`, `http://127.0.0.1:9000`.
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String prefix;

  /// `true` for MinIO / older endpoints that require `/{bucket}/{key}`
  /// rather than the default virtual-host style `https://{bucket}.host/{key}`.
  final bool usePathStyle;

  final http.Client _http;
  final DateTime Function() _clock;

  static const _service = 's3';

  @override
  String get destinationLabel => 'S3 ($bucket)';

  @override
  bool get isConfigured =>
      endpoint.isNotEmpty &&
      bucket.isNotEmpty &&
      accessKeyId.isNotEmpty &&
      secretAccessKey.isNotEmpty;

  // ---------------------------------------------------------------------------
  // CloudSyncAdapter
  // ---------------------------------------------------------------------------

  @override
  Future<List<CloudObject>> list() async {
    final query = <String, String>{
      'list-type': '2',
      if (prefix.isNotEmpty) 'prefix': prefix,
    };
    final uri = _buildUri(key: '', query: query);
    final res = await _signedRequest(method: 'GET', uri: uri, body: const []);
    if (res.statusCode != 200) {
      throw CloudSyncException(
        'S3 list failed: ${res.statusCode} ${res.body}',
      );
    }
    return _parseListV2(res.body);
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    final uri = _buildUri(key: key);
    final res = await _signedRequest(
      method: 'PUT',
      uri: uri,
      body: bytes,
      contentType: 'application/octet-stream',
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'S3 PUT $key failed: ${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<Uint8List> get(String key) async {
    final uri = _buildUri(key: key);
    final res = await _signedRequest(
      method: 'GET',
      uri: uri,
      body: const [],
    );
    if (res.statusCode != 200) {
      throw CloudSyncException(
        'S3 GET $key failed: ${res.statusCode} ${res.body}',
      );
    }
    return Uint8List.fromList(res.bodyBytes);
  }

  @override
  Future<void> delete(String key) async {
    final uri = _buildUri(key: key);
    final res = await _signedRequest(
      method: 'DELETE',
      uri: uri,
      body: const [],
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'S3 DELETE $key failed: ${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<void> rename(String fromKey, String toKey) async {
    // S3 has no native rename — fall back to copy + delete.
    final uri = _buildUri(key: toKey);
    final copySource = '/$bucket/$fromKey';
    final res = await _signedRequest(
      method: 'PUT',
      uri: uri,
      body: const [],
      extraHeaders: {'x-amz-copy-source': copySource},
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'S3 COPY $fromKey -> $toKey failed: ${res.statusCode}',
      );
    }
    await delete(fromKey);
  }

  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // SigV4 implementation
  // ---------------------------------------------------------------------------

  /// Public for tests: builds a signed Authorization header string for
  /// the given request without firing it. The exact bytes a real PUT
  /// would carry are passed in via [body].
  ///
  /// Returns the full set of headers (including `Authorization`,
  /// `x-amz-date`, `x-amz-content-sha256`, `host`).
  Map<String, String> debugSignHeaders({
    required String method,
    required Uri uri,
    required List<int> body,
    String? contentType,
    Map<String, String>? extraHeaders,
    DateTime? at,
  }) {
    return _buildSignedHeaders(
      method: method,
      uri: uri,
      body: body,
      contentType: contentType,
      extraHeaders: extraHeaders,
      now: at ?? _clock(),
    );
  }

  Future<http.Response> _signedRequest({
    required String method,
    required Uri uri,
    required List<int> body,
    String? contentType,
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _buildSignedHeaders(
      method: method,
      uri: uri,
      body: body,
      contentType: contentType,
      extraHeaders: extraHeaders,
      now: _clock(),
    );
    final req = http.Request(method, uri);
    req.headers.addAll(headers);
    if (body.isNotEmpty) {
      req.bodyBytes = body is Uint8List ? body : Uint8List.fromList(body);
    }
    final streamed = await _http.send(req);
    return http.Response.fromStream(streamed);
  }

  Map<String, String> _buildSignedHeaders({
    required String method,
    required Uri uri,
    required List<int> body,
    String? contentType,
    Map<String, String>? extraHeaders,
    required DateTime now,
  }) {
    final amzDate = _amzDate(now);
    final dateStamp = amzDate.substring(0, 8);
    final payloadHash = _sha256Hex(body);

    final headers = <String, String>{
      'host': uri.host + (uri.hasPort ? ':${uri.port}' : ''),
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      if (contentType != null) 'content-type': contentType,
      if (extraHeaders != null) ...extraHeaders.map(
        (k, v) => MapEntry(k.toLowerCase(), v),
      ),
    };

    final sortedHeaderKeys = headers.keys.toList()..sort();
    final canonicalHeaders = sortedHeaderKeys
        .map((k) => '$k:${headers[k]!.trim()}\n')
        .join();
    final signedHeaders = sortedHeaderKeys.join(';');

    final canonicalQuery = _canonicalQuery(uri);
    final canonicalUri = _canonicalUri(uri);

    final canonicalRequest = [
      method,
      canonicalUri,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final signingKey = _signingKey(secretAccessKey, dateStamp, region, _service);
    final signature = _hex(_hmacSha256(signingKey, utf8.encode(stringToSign)));

    final auth =
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    return {
      ...headers,
      'Authorization': auth,
    };
  }

  // ---------------------------------------------------------------------------
  // URI / canonicalisation helpers
  // ---------------------------------------------------------------------------

  Uri _buildUri({required String key, Map<String, String>? query}) {
    final base = Uri.parse(endpoint);
    final scheme = base.scheme;
    final host = base.host;
    final port = base.hasPort ? base.port : null;

    String pathPrefix;
    String authority;
    if (usePathStyle) {
      authority = port != null ? '$host:$port' : host;
      pathPrefix = '/$bucket';
    } else {
      authority = port != null
          ? '$bucket.$host:$port'
          : '$bucket.$host';
      pathPrefix = '';
    }

    final path = key.isEmpty
        ? '$pathPrefix/'
        : '$pathPrefix/${_encodePathSegments(key)}';

    return Uri(
      scheme: scheme,
      host: authority.split(':').first,
      port: authority.contains(':') ? int.parse(authority.split(':').last) : null,
      path: path,
      queryParameters: query,
    );
  }

  static String _encodePathSegments(String key) {
    return key.split('/').map(Uri.encodeComponent).join('/');
  }

  static String _canonicalUri(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    // SigV4 requires per-segment URI encoding, but the segments are already
    // encoded by Uri above for non-bucket paths. Re-normalise to ensure no
    // double-encoding for empty segments.
    return path;
  }

  static String _canonicalQuery(Uri uri) {
    if (uri.queryParameters.isEmpty) return '';
    final sortedKeys = uri.queryParameters.keys.toList()..sort();
    return sortedKeys
        .map((k) =>
            '${Uri.encodeComponent(k)}=${Uri.encodeComponent(uri.queryParameters[k]!)}')
        .join('&');
  }

  static String _amzDate(DateTime t) {
    final u = t.toUtc();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${pad(u.month)}${pad(u.day)}T'
        '${pad(u.hour)}${pad(u.minute)}${pad(u.second)}Z';
  }

  static String _sha256Hex(List<int> body) =>
      _hex(sha256.convert(body).bytes);

  static List<int> _hmacSha256(List<int> key, List<int> data) {
    final mac = Hmac(sha256, key);
    return mac.convert(data).bytes;
  }

  static List<int> _signingKey(
    String secret,
    String dateStamp,
    String region,
    String service,
  ) {
    final kDate = _hmacSha256(utf8.encode('AWS4$secret'), utf8.encode(dateStamp));
    final kRegion = _hmacSha256(kDate, utf8.encode(region));
    final kService = _hmacSha256(kRegion, utf8.encode(service));
    return _hmacSha256(kService, utf8.encode('aws4_request'));
  }

  static String _hex(List<int> bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // ListObjectsV2 (XML) parser — minimal, no external XML dep.
  // ---------------------------------------------------------------------------

  static List<CloudObject> _parseListV2(String xml) {
    final results = <CloudObject>[];
    final contentRegex = RegExp(r'<Contents>(.*?)</Contents>', dotAll: true);
    final keyRegex = RegExp(r'<Key>(.*?)</Key>');
    final sizeRegex = RegExp(r'<Size>(.*?)</Size>');
    final lastModRegex = RegExp(r'<LastModified>(.*?)</LastModified>');
    for (final m in contentRegex.allMatches(xml)) {
      final block = m.group(1)!;
      final key = keyRegex.firstMatch(block)?.group(1) ?? '';
      final sizeStr = sizeRegex.firstMatch(block)?.group(1) ?? '0';
      final modStr = lastModRegex.firstMatch(block)?.group(1) ?? '';
      if (key.isEmpty) continue;
      results.add(CloudObject(
        key: key,
        size: int.tryParse(sizeStr) ?? 0,
        lastModified:
            DateTime.tryParse(modStr) ?? DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    return results;
  }
}
