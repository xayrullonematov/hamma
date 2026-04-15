enum AiProvider {
  openAi,
  gemini,
  openRouter,
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
    }
  }
}

AiProvider aiProviderFromStorage(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'gemini':
      return AiProvider.gemini;
    case 'openrouter':
      return AiProvider.openRouter;
    case 'openai':
    default:
      return AiProvider.openAi;
  }
}
