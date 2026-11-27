# Pocket Consultant for iPhone and Mac

This personal build uses Apple's on-device text model. Conversation history and learned memories are stored in the app's own container. It has its own bundle identifier. The iPhone chat does not use the Swift package's HTTP provider, a service account, a Lark endpoint or an API key. The model's identity is Apple. The app can run with an optional archive of dated user memories.

## Apple silicon Mac

Download the **Pocket-Consultant-Mac** artifact from the successful **Personal Mac app** run for this branch. Unzip the artifact and the app archive it contains. The CI build is ad-hoc signed for personal testing. It has no Developer ID notarisation. Chat requires a ready Apple Intelligence model on macOS 26 or later. macOS 14 or later can open the archive and public guides independently.

To build locally with Xcode 26 and XcodeGen, generate the project and run the **PocketConsultantMac** scheme with **My Mac** selected.

## Install an iPhone build

On a Mac with Xcode 26 or later and XcodeGen installed, run these commands from the project folder.

```bash
xcodegen generate
open LarkAISolutionsConsultant.xcodeproj
```

Select the LarkAISolutionsConsultantApp target. In Signing & Capabilities, select your Apple development team. Connect your iPhone, choose it as the run destination, and press Run. Enable Developer Mode on the iPhone if Xcode requests it.

The archive screen supports iOS 17 and later. Chat requires iOS 26 or later, a device and language supported by Apple Intelligence, and a ready on-device model. The composer displays the model's status. Voice dictation uses the device's speech recognizer, and the speaker button reads replies aloud. This build accepts text and dictation.

## Personal memories

Open **Memories → Import JSON** to select your private archive from Files or Finder. The app copies the notes into its own local storage and makes them searchable immediately. An import updates notes with matching IDs and keeps the other notes. The Mac and iPhone keep separate copies. You can also bundle an archive with a personal iPhone build by placing ConsultantMemory.json in iOSApp before running XcodeGen. Use a JSON array of objects with string fields id, title, source, date and text, plus a keywords array of lowercase words. The Memories screen can display and search the archive without a model. During a chat, up to three matching excerpts are included in the Apple model's local prompt. Clearing chat resets conversation and learned history. The bundled source archive stays available.

Git ignores the personal JSON file. Remove it and regenerate the project before distributing a copy to someone else.

## Lark and TikTok sources

Open **Sources** to see the model used by this build, its account connections and offline summaries of official guides. Only opening a guide visits its website. When a question names Lark or TikTok, chat includes the corresponding summaries in the local prompt. Replies list the guide URLs and any dated archive notes supplied for that turn. These references describe the material available to the model. Account status and internal platform decisions require separate evidence.
