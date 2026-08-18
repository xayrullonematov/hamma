import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';
import 'package:hamma/plugins/builtin/kubernetes_plugin.dart';
import 'package:hamma/plugins/hamma_api.dart';
import 'package:hamma/plugins/hamma_plugin.dart';
import 'package:mocktail/mocktail.dart';

class MockHammaApi extends Mock implements HammaApi {}

void main() {
  group('KubernetesPlugin', () {
    late MockHammaApi mockApi;
    late KubernetesPlugin plugin;

    setUp(() {
      mockApi = MockHammaApi();
      when(() => mockApi.serverInfo).thenReturn(
        const PluginServerInfo(
          id: 's1',
          name: 'test-server',
          host: 'localhost',
          port: 22,
          username: 'root',
        ),
      );
      plugin = KubernetesPlugin();
    });

    testWidgets('renders loading state initially', (tester) async {
      when(() => mockApi.runCommand(any())).thenAnswer(
        (_) => Future.delayed(
          const Duration(milliseconds: 100),
          () => const PluginCommandResult(
            command: '...',
            stdout: '',
            riskLevel: CommandRiskLevel.low,
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('renders empty state when no pods exist', (tester) async {
      when(() => mockApi.runCommand(any())).thenAnswer(
        (_) async => const PluginCommandResult(
          command: '...',
          stdout: '',
          riskLevel: CommandRiskLevel.low,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NO PODS RETURNED'), findsOneWidget);
    });

    testWidgets('renders error state when kubectl returns invalid json', (tester) async {
      when(() => mockApi.runCommand(any())).thenAnswer(
        (_) async => const PluginCommandResult(
          command: '...',
          stdout: 'invalid json',
          riskLevel: CommandRiskLevel.low,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // JSON parsing failure triggers error state (FormatException)
      expect(find.textContaining('FormatException: Unexpected character'), findsOneWidget);
    });

    testWidgets('renders table with pods', (tester) async {
      final podsJson = {
        'items': [
          {
            'metadata': {'name': 'nginx', 'namespace': 'default'},
            'spec': {'nodeName': 'node-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'ready': true}
              ]
            }
          },
          {
            'metadata': {'name': 'db', 'namespace': 'prod'},
            'status': {
              'phase': 'Pending'
            }
          }
        ]
      };

      when(() => mockApi.runCommand(any())).thenAnswer(
        (_) async => PluginCommandResult(
          command: '...',
          stdout: jsonEncode(podsJson),
          riskLevel: CommandRiskLevel.low,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('default/nginx'), findsOneWidget);
      expect(find.text('phase: Running  ·  node: node-1  ·  ready: 1/1'), findsOneWidget);

      expect(find.text('prod/db'), findsOneWidget);
      expect(find.text('phase: Pending  ·  node: -  ·  ready: 0/0'), findsOneWidget);
    });

    testWidgets('shows logs dialog when clicking LOGS', (tester) async {
      final podsJson = {
        'items': [
          {
            'metadata': {'name': 'nginx', 'namespace': 'default'},
            'spec': {'nodeName': 'node-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'ready': true}
              ]
            }
          },
        ]
      };

      when(() => mockApi.runCommand('kubectl get pods -A -o json')).thenAnswer(
        (_) async => PluginCommandResult(
          command: '...',
          stdout: jsonEncode(podsJson),
          riskLevel: CommandRiskLevel.low,
        ),
      );

      when(() => mockApi.runCommand('kubectl logs -n default nginx --tail=200')).thenAnswer(
        (_) async => const PluginCommandResult(
          command: '...',
          stdout: 'nginx started\nlistening on port 80',
          riskLevel: CommandRiskLevel.low,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Click the logs button
      await tester.tap(find.text('LOGS'));
      await tester.pumpAndSettle();

      // Dialog should appear
      expect(find.text('LOGS · default/nginx'), findsOneWidget);
      expect(find.text('nginx started\nlistening on port 80'), findsOneWidget);

      // Close dialog
      await tester.tap(find.text('CLOSE'));
      await tester.pumpAndSettle();
      expect(find.text('LOGS · default/nginx'), findsNothing);
    });

    testWidgets('handles HammaApiException when fetching logs', (tester) async {
      final podsJson = {
        'items': [
          {
            'metadata': {'name': 'nginx', 'namespace': 'default'},
            'spec': {'nodeName': 'node-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'ready': true}
              ]
            }
          },
        ]
      };

      when(() => mockApi.runCommand('kubectl get pods -A -o json')).thenAnswer(
        (_) async => PluginCommandResult(
          command: '...',
          stdout: jsonEncode(podsJson),
          riskLevel: CommandRiskLevel.low,
        ),
      );

      when(() => mockApi.runCommand('kubectl logs -n default nginx --tail=200')).thenThrow(
        const HammaApiException('Risk level moderate'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Click the logs button
      await tester.tap(find.text('LOGS'));
      await tester.pumpAndSettle();

      // Snackbar should appear
      expect(find.text('Risk level moderate'), findsOneWidget);
    });

    testWidgets('handles generic error when fetching logs', (tester) async {
      final podsJson = {
        'items': [
          {
            'metadata': {'name': 'nginx', 'namespace': 'default'},
            'spec': {'nodeName': 'node-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'ready': true}
              ]
            }
          },
        ]
      };

      when(() => mockApi.runCommand('kubectl get pods -A -o json')).thenAnswer(
        (_) async => PluginCommandResult(
          command: '...',
          stdout: jsonEncode(podsJson),
          riskLevel: CommandRiskLevel.low,
        ),
      );

      when(() => mockApi.runCommand('kubectl logs -n default nginx --tail=200')).thenThrow(
        Exception('Network failed'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Click the logs button
      await tester.tap(find.text('LOGS'));
      await tester.pumpAndSettle();

      // Snackbar should appear
      expect(find.text('kubectl logs failed: Exception: Network failed'), findsOneWidget);
    });

    testWidgets('refreshes pods on retry click after error', (tester) async {
      var fail = true;
      when(() => mockApi.runCommand(any())).thenAnswer((_) async {
        if (fail) {
          fail = false;
          throw Exception('Timeout');
        }
        return const PluginCommandResult(
          command: '...',
          stdout: '',
          riskLevel: CommandRiskLevel.low,
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Exception: Timeout'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await tester.pumpAndSettle();

      expect(find.text('NO PODS RETURNED'), findsOneWidget);
    });

    testWidgets('refreshes pods on refresh button click', (tester) async {
      var count = 0;
      when(() => mockApi.runCommand(any())).thenAnswer((_) async {
        count++;
        if (count == 1) {
          return const PluginCommandResult(
            command: '...',
            stdout: '',
            riskLevel: CommandRiskLevel.low,
          );
        } else {
          final podsJson = {
            'items': [
              {
                'metadata': {'name': 'new-pod', 'namespace': 'default'},
              },
            ]
          };
          return PluginCommandResult(
            command: '...',
            stdout: jsonEncode(podsJson),
            riskLevel: CommandRiskLevel.low,
          );
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => plugin.buildPanel(context, mockApi)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NO PODS RETURNED'), findsOneWidget);

      await tester.tap(find.text('REFRESH'));
      await tester.pumpAndSettle();

      expect(find.text('default/new-pod'), findsOneWidget);
    });
  });
}
