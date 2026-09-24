# Lark AI Solutions Consultant

This repository contains the foundation for a standalone iPhone consultant app, built to evolve feature-by-feature.

## What is included
- A Swift package (`LarkAISolutionsConsultant`) with:
  - consultant chat/session models
  - provider abstraction (`AIProvider`)
  - HTTP + mock providers
  - local conversation persistence
  - adaptive learning engine (topic extraction + goal tracking)
  - advanced long-term memory store with semantic recall
  - controller layer for MVP chat flow
- iOS app source scaffold in `/iOSApp` using SwiftUI
- Initial V1 scope and roadmap docs in `/docs`
- CI workflow to run `swift test`

## Configuration
Set these environment variables for real API integration:
- `LARK_AI_ENDPOINT`
- `LARK_AI_API_KEY`
- `LARK_AI_MODEL` (optional)
- `LARK_AI_MAX_RETRIES` (optional)

If `LARK_AI_ENDPOINT` is not set, the app uses a local mock provider.

## Learning and memory capabilities
- Learns durable memory summaries from user prompts.
- Reinforces recurring themes to strengthen important memories.
- Tracks top topics and recent user goals over time.
- Recalls relevant memories and injects them into provider prompts for personalization.
- Persists both conversation history and learning state across sessions.
- Supports multimodal prompts with image attachments (common image MIME types).
- Accepts both native `reply` API responses and OpenAI-style `choices[].message.content` responses.
- Injects built-in company knowledge base and plugin context for TikTok, Facebook, Instagram, Wix, Shopify, Amazon, Lark, Claude AI, Munus, ByteDance, Canva, and AnyCross when prompts reference those platforms.
- Adds cross-platform plugin suggestions when prompts ask for integrations, connectors, plugins, or multi-platform workflows.
- Injects built-in skill context for image creation, image editing, comic book creation, picture design, short video creation, adaptive self-learning, and auto-selected plug-ins/skills when prompts or image inputs indicate those workflows.

## Testing
```bash
swift test
```

## Documentation
- `/home/runner/work/tests/tests/docs/V1_SCOPE.md`
- `/home/runner/work/tests/tests/docs/ROADMAP.md`
