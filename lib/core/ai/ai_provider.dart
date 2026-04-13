enum AiProvider {
  openAi,
  gemini,
}

extension AiProviderPresentation on AiProvider {
  String get storageValue {
    switch (this) {
      case AiProvider.openAi:
        return 'openai';
      case AiProvider.gemini:
        return 'gemini';
    }
  }

  String get label {
    switch (this) {
      case AiProvider.openAi:
        return 'OpenAI';
      case AiProvider.gemini:
        return 'Gemini';
    }
  }

  String get helperText {
    switch (this) {
      case AiProvider.openAi:
        return 'OpenAI uses a paid API key.';
      case AiProvider.gemini:
        return 'Gemini may have beta/free-tier quota limits.';
    }
  }
}

AiProvider aiProviderFromStorage(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'gemini':
      return AiProvider.gemini;
    case 'openai':
    default:
      return AiProvider.openAi;
  }
}
