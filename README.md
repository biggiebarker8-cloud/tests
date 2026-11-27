# Pocket Consultant for iPhone

This personal build uses Apple's on-device text model. Conversation history and learned memories are stored in the app's own container. It has its own bundle identifier. The iPhone chat does not use the Swift package's HTTP provider, a service account, a Lark endpoint or an API key. The model's identity is Apple. The app can run with an optional archive of dated user memories.

## Install a personal build

On a Mac with Xcode 26 or later and XcodeGen installed, run these commands from the project folder.

```bash
xcodegen generate
open LarkAISolutionsConsultant.xcodeproj
```

Select the LarkAISolutionsConsultantApp target. In Signing & Capabilities, select your Apple development team. Connect your iPhone, choose it as the run destination, and press Run. Enable Developer Mode on the iPhone if Xcode requests it.

The archive screen supports iOS 17 and later. Chat requires iOS 26 or later, a device and language supported by Apple Intelligence, and a ready on-device model. The composer displays the model's status. Voice dictation uses the device's speech recognizer, and the speaker button reads replies aloud. This build accepts text and dictation.

## Personal memories

Before running XcodeGen, place the optional ConsultantMemory.json in iOSApp. Use a JSON array of objects with string fields id, title, source, date and text, plus a keywords array of lowercase words. The Memories screen can display and search the archive without a model. During a chat, up to three matching excerpts are included in the Apple model's local prompt. Clearing chat resets conversation and learned history. The bundled source archive stays available.

Git ignores the personal JSON file. Remove it and regenerate the project before distributing a copy to someone else.
