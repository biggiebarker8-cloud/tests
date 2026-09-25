# Lark AI Solutions Consultant

This repository contains the foundation for a standalone iPhone consultant app focused on Microsoft-only scenarios and products.

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
- Injects built-in Microsoft company knowledge base and plugin context when prompts reference Microsoft products and programs.
- Adds standalone Microsoft-only guidance when prompts explicitly exclude non-Microsoft platforms or projects.
- Injects built-in skill context for image creation, image editing, comic book creation, picture design, short video creation, website building, website permissions management (excluding payment/admin charge privileges), core memory vault, story universe continuity, assistant personality styling, voice and hearing interaction, adaptive self-learning, and auto-selected plug-ins/skills when prompts or image inputs indicate those workflows.
- Injects structured domain templates for rollout planning, architecture guidance, and security governance prompts to make responses easier to extend and reuse.

## Testing
```bash
swift test
```

## Documentation
- `/home/runner/work/tests/tests/docs/V1_SCOPE.md`
- `/home/runner/work/tests/tests/docs/ROADMAP.md`
