import 'package:http/http.dart' as http;
import 'dart:convert';

class GeminiService {
  final http.Client client;
  final String apiKey;

  GeminiService({required this.client, required this.apiKey});

  Future<String> generateContent(String prompt) async {
    final response = await client.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ]
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['candidates'][0]['content']['parts'][0]['text'] as String;
    } else {
      throw Exception('Failed to generate content: ${response.statusCode}');
    }
  }
}
