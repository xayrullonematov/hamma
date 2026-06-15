## 2024-06-12 - [Missing API Key Scrubbing]
**Vulnerability:** Gemini API keys (`AIza...`) were not explicitly scrubbed from error messages, potentially leading to credentials leaking in logs or Sentry payloads.
**Learning:** `ErrorScrubber` handled OpenAI and JWTs, but as Gemini was added, the scrubber was not updated.
**Prevention:** Whenever a new AI provider or external service is integrated, ensure their specific credential format is added to the `ErrorScrubber` patterns.
