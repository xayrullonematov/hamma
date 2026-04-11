import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/api_key_storage.dart';
import 'package:hamma/main.dart';

void main() {
  testWidgets('shows saved server home screen', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      const AiServerApp(
        apiKeyStorage: ApiKeyStorage(),
        initialApiKey: '',
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Saved Servers'), findsOneWidget);
    expect(find.text('Add Server'), findsOneWidget);
  });
}
