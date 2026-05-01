enum AiProvider {
  openAi,
  gemini,
  openRouter,
  local,
}

extension AiProviderPresentation on AiProvider {
  String get storageValue {
    switch (this) {
      case AiProvider.openAi:
        return 'openai';
      case AiProvider.gemini:
        return 'gemini';
      case AiProvider.openRouter:
        return 'openrouter';
      case AiProvider.local:
        return 'local';
    }
  }

  String get label {
    switch (this) {
      case AiProvider.openAi:
        return 'OpenAI';
      case AiProvider.gemini:
        return 'Gemini';
      case AiProvider.openRouter:
        return 'OpenRouter';
      case AiProvider.local:
        return 'Local AI';
    }
  }

  String get helperText {
    switch (this) {
      case AiProvider.openAi:
        return 'OpenAI uses a paid API key.';
      case AiProvider.gemini:
        return 'Gemini may have beta/free-tier quota limits.';
      case AiProvider.openRouter:
        return 'Access hundreds of models via OpenRouter.ai';
      case AiProvider.local:
        return 'Zero-trust. No API key. Runs fully offline via Ollama or any OpenAI-compatible local engine on your machine.';
    }
  }

  bool get requiresApiKey {
    switch (this) {
      case AiProvider.openAi:
      case AiProvider.gemini:
      case AiProvider.openRouter:
        return true;
      case AiProvider.local:
        return false;
    }
  }

  bool get isLocal {
    return this == AiProvider.local;
  }
}

AiProvider aiProviderFromStorage(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'gemini':
      return AiProvider.gemini;
    case 'openrouter':
      return AiProvider.openRouter;
    case 'local':
      return AiProvider.local;
    case 'openai':
    default:
      return AiProvider.openAi;
  }
}
