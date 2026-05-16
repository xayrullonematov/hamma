// lib/core/ai/ai_command_service.dart  — PATCH: AiApiConfig.forProvider (local case)
//
// FIX 3: The model fallback for AiProvider.local changed from the Ollama
// shortname 'gemma3' to BundledModelCatalog.defaultPick.id ('gemma3-1b-it-q4').
//
// WHY THIS MATTERS:
//   • The BundledEngine loads its model with the BundledModel.id string
//     (e.g. 'gemma3-1b-it-q4') as both the on-disk filename stem AND the
//     model id it advertises on GET /v1/models.
//   • LocalEngineHealthMonitor calls GET /v1/models and checks that AT LEAST
//     ONE model is present. If the model name in the POST body doesn't match
//     what's loaded, the engine may return a 404 or empty list — causing the
//     monitor to flip to "offline".
//   • External Ollama/LM Studio users who have explicitly saved their model
//     name (e.g. 'llama3') via settings are unaffected: the (localModel?.trim()
//     .isNotEmpty ?? false) guard takes precedence over the fallback.
//
// ONLY THE local CASE IN forProvider IS CHANGED. All other providers are
// identical to the original. Drop this file in place of the existing one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../vault/vault_redactor.dart';
import 'ai_provider.dart';
import 'bundled_model_catalog.dart';   // ← NEW IMPORT (needed for defaultPick.id)
import 'bundled_model_downloader.dart';
import 'command_risk_assessor.dart';
import 'inference_engine.dart';
import 'ollama_client.dart';

class AiApiConfig {
  const AiApiConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  factory AiApiConfig.forProvider({
    required AiProvider provider,
    required String apiKey,
    String? openRouterModel,
    String? localEndpoint,
    String? localModel,
  }) {
    switch (provider) {
      case AiProvider.openAi:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: apiKey,
          model: 'gpt-4.1-mini',
        );
      case AiProvider.gemini:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: apiKey,
          model: 'gemini-2.5-flash',
        );
      case AiProvider.openRouter:
        return AiApiConfig(
          provider: provider,
          baseUrl: 'https://openrouter.ai/api/v1',
          apiKey: apiKey,
          model: (openRouterModel?.trim().isNotEmpty ?? false)
              ? openRouterModel!.trim()
              : 'meta-llama/llama-3.1-8b-instruct:free',
        );

      case AiProvider.local:
        final endpoint = (localEndpoint?.trim().isNotEmpty ?? false)
            ? localEndpoint!.trim()
            : 'http://localhost:11434';

        final isMobile = Platform.isAndroid || Platform.isIOS;
        if (!isMobile && !OllamaClient.isLoopbackEndpoint(endpoint)) {
          throw ArgumentError.value(
            endpoint,
            'localEndpoint',
            'Local AI endpoints must point at loopback (127.0.0.0/8, ::1, '
                'or localhost). Refusing to send prompts to a non-loopback '
                'host.',
          );
        }
        return AiApiConfig(
          provider: provider,
          baseUrl: '$endpoint/v1',
          apiKey: 'local',
          // FIX: was 'gemma3' (an Ollama shortname the BundledEngine doesn't
          // recognise). Now defaults to BundledModelCatalog.defaultPick.id
          // ('gemma3-1b-it-q4') which is the exact id the engine advertises
          // on GET /v1/models and expects in POST /v1/chat/completions.
          //
          // External Ollama users: if you pulled 'gemma3' with `ollama pull
          // gemma3` you should save the model name explicitly in Settings →
          // Local AI → Model Name so the user-supplied value takes precedence
          // over this fallback.
          model: (localModel?.trim().isNotEmpty ?? false)
              ? localModel!.trim()
              : BundledModelCatalog.defaultPick.id,
        );
    }
  }

  final AiProvider provider;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured {
    if (provider == AiProvider.local) {
      return baseUrl.isNotEmpty;
    }
    return apiKey.trim().isNotEmpty;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Everything below this line is UNCHANGED from the original file.
// Paste the rest of your ai_command_service.dart here.
// ─────────────────────────────────────────────────────────────────────────────
