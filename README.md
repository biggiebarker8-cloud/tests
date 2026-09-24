# Lark AI Solutions Consultant

This repository contains the foundation for a standalone iPhone consultant app, built to evolve feature-by-feature.

## What is included
- A Swift package (`LarkAISolutionsConsultant`) with:
  - consultant chat/session models
  - provider abstraction (`AIProvider`)
  - HTTP + mock providers
  - local conversation persistence
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

## Testing
```bash
swift test
```

## Documentation
- `/home/runner/work/tests/tests/docs/V1_SCOPE.md`
- `/home/runner/work/tests/tests/docs/ROADMAP.md`
