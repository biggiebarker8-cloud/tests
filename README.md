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
- CI workflow to run `swift test` on both pushes and pull requests

## Build the iPhone app
On a Mac with Xcode 16 or later, install XcodeGen (`brew install xcodegen`), then run:

```bash
xcodegen generate
open LarkAISolutionsConsultant.xcodeproj
```

Select the `LarkAISolutionsConsultantApp` scheme and an iPhone simulator, then press Run. The app starts with a local mock response until an endpoint is configured. To run on your own iPhone, select your Apple development team under Signing & Capabilities in Xcode and choose the device. A signed distribution build requires your Apple signing setup.

The iOS Simulator Build workflow checks that the app compiles. The Swift Tests workflow checks the package separately.

## Configuration
Set these environment variables for real API integration:
- `LARK_AI_ENDPOINT`
- `LARK_AI_API_KEY`
- `LARK_AI_MODEL` (optional)
- `LARK_AI_MAX_RETRIES` (optional)

If `LARK_AI_ENDPOINT` is not set, the app uses a local mock provider. For local simulator development, set the variables in the Xcode scheme's Run environment. iOS apps do not read environment variables from your Mac automatically, and launch environment values are not a suitable production credential store. Use your own HTTPS backend for production; keep provider API keys on the server.

## Learning and memory capabilities
- Learns durable memory summaries from user prompts.
- Reinforces recurring themes to strengthen important memories.
- Tracks top topics and recent user goals over time.
- Recalls relevant memories and injects them into provider prompts for personalization.
- Persists both conversation history and learning state across sessions.
- Supports multimodal prompts with image attachments (common image MIME types).
- Accepts both native `reply` API responses and OpenAI-style `choices[].message.content` responses.
- Injects built-in company knowledge base and plugin context for TikTok, TikTok Agency, Microsoft, Facebook, Instagram, Wix, Shopify, Amazon, Lark, Claude AI, Munus, ByteDance, Canva, and AnyCross when prompts reference those platforms.
- Adds cross-platform plugin suggestions when prompts ask for integrations, connectors, plugins, or multi-platform workflows.
- Injects built-in skill context for image creation, image editing, comic book creation, picture design, short video creation, website building, website permissions management (excluding payment/admin charge privileges), core memory vault, story universe continuity, assistant personality styling, voice and hearing interaction, adaptive self-learning, and auto-selected plug-ins/skills when prompts or image inputs indicate those workflows.
- Injects structured domain templates for rollout planning, architecture guidance, and security governance prompts to make responses easier to extend and reuse.

## Testing
```bash
swift test
```

## Documentation
- `docs/V1_SCOPE.md`
- `docs/ROADMAP.md`
