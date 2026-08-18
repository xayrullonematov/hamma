import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/services/gemini_service.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'dart:convert';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('http://localhost'));
  });

  group('GeminiService', () {
    late MockHttpClient mockHttpClient;
    late GeminiService geminiService;
    const testApiKey = 'test_api_key';

    setUp(() {
      mockHttpClient = MockHttpClient();
      geminiService = GeminiService(client: mockHttpClient, apiKey: testApiKey);
    });

    test('generateContent returns content on successful request', () async {
      final mockResponse = http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Hello, world!'}
                  ]
                }
              }
            ]
          }),
          200);

      when(() => mockHttpClient.post(
            any(),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
          )).thenAnswer((_) async => mockResponse);

      final result = await geminiService.generateContent('Say hello');

      expect(result, 'Hello, world!');

      final expectedUri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=$testApiKey');

      verify(() => mockHttpClient.post(
            expectedUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': 'Say hello'}
                  ]
                }
              ]
            }),
          )).called(1);
    });

    test('generateContent throws an exception on failed request', () async {
      final mockResponse = http.Response('Error message', 400);

      when(() => mockHttpClient.post(
            any(),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
          )).thenAnswer((_) async => mockResponse);

      expect(
        () => geminiService.generateContent('Say hello'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', 'Exception: Failed to generate content: 400')),
      );
    });
  });
}
