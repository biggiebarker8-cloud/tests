# Pocket Consultant for iPhone and Mac

This personal build supports OpenAI and Apple on-device chat. Open **OpenAI**, enter your personal OpenAI API key in the secure field, then select **Save key and use OpenAI**. Enter the key separately on each device. The app stores the key in Keychain. Only sending a message calls the OpenAI Responses API. The request uses `gpt-5.4-mini`, includes photos attached to the current message, recent text turns and relevant context, and sets `store: false`. OpenAI bills your API project. For a distributed app with a shared developer key, keep that key on an authenticated backend.

Apple on-device chat remains available before you select OpenAI and after you remove the key. Neither chat route uses a Lark account or endpoint. Conversation history and the optional archive of dated user memories stay in the app’s local container. In OpenAI mode, sending a question shares selected context with OpenAI.

## Apple silicon Mac

Download the **Pocket-Consultant-Mac** artifact from the successful **Personal Mac app** run for this branch. Unzip the artifact and the app archive it contains. The CI build is ad-hoc signed for personal testing. It has no Developer ID notarisation. OpenAI chat runs on macOS 14 or later. Apple chat requires a ready Apple Intelligence model on macOS 26 or later. macOS 14 or later can open the archive and public guides independently.

To build locally with Xcode 26 and XcodeGen, generate the project and run the **PocketConsultantMac** scheme with **My Mac** selected.

## Install an iPhone build

On a Mac with Xcode 26 or later and XcodeGen installed, run these commands from the project folder.

```bash
xcodegen generate
open LarkAISolutionsConsultant.xcodeproj
```

Select the LarkAISolutionsConsultantApp target. In Signing & Capabilities, select your Apple development team. Connect your iPhone, choose it as the run destination, and press Run. Enable Developer Mode on the iPhone if Xcode requests it.

The archive screen supports iOS 17 and later. OpenAI chat supports iOS 17 or later. Apple chat requires iOS 26 or later, a device and language supported by Apple Intelligence, and a ready on-device model. The composer displays the model's status. Voice dictation uses the device's speech recognizer, and the speaker button reads replies aloud. In OpenAI mode, use the photo button to attach up to six photos on iPhone or Mac, then press Send. On iPhone you can dictate the question and play the answer aloud. Photos are resized and sent as JPEGs. Follow-up turns include recent text. Reattach a photo to have the model inspect it again.

## Run the browser app

The browser version includes a responsive chat interface and a same-origin Node.js proxy. Keep the Lark API key on the server; do not put it in browser code or client-side storage.

1. Install Node.js 18 or later.
2. Set `LARK_AI_ENDPOINT` and `LARK_AI_API_KEY` in the server environment. Optionally set `LARK_AI_MODEL`, `PORT`, and `HOST` (defaults to `lark-consultant-v1`, `4173`, and `127.0.0.1`).
3. Run `npm run start:web` and open `http://localhost:4173`.

The browser keeps conversation history in that browser's local storage. Image attachments are sent through the server proxy and support JPEG, PNG, GIF, and WebP files (up to six images, 5 MB each). For production, put the app behind HTTPS and configure the server environment through your hosting provider's secret management.

## Personal memories

Open **Memories → Import JSON** to select your private archive from Files or Finder. The app copies the notes into its own local storage and makes them searchable immediately. An import updates notes with matching IDs and keeps the other notes. The Mac and iPhone keep separate copies. You can also bundle an archive with a personal iPhone build by placing ConsultantMemory.json in iOSApp before running XcodeGen. Use a JSON array of objects with string fields id, title, source, date and text, plus a keywords array of lowercase words. The Memories screen can display and search the archive without a model. During a chat, up to three matching excerpts are supplied to the selected chat provider. Clearing chat resets conversation and learned history. The bundled source archive stays available.

Git ignores the personal JSON file. Remove it and regenerate the project before distributing a copy to someone else.

## Lark and TikTok sources

Open **Sources** to see the model used by this build, its account connections and offline summaries of official guides. Only opening a guide visits its website. When a question names Lark or TikTok, chat includes the corresponding summaries in the prompt. Replies list the guide URLs and any dated archive notes supplied for that turn. These references describe the material available to the model. Account status and internal platform decisions require separate evidence.

## Testing

```bash
swift test
npm run test:web
```

## Documentation

- `docs/V1_SCOPE.md`
- `docs/ROADMAP.md`
