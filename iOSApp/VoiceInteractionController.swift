import AVFoundation
import Speech
import SwiftUI

@MainActor
final class VoiceInteractionController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isFinishingRecognition = false
    @Published private(set) var isSpeaking = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTranscript: ((String) -> Void)?
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    func startListening(onTranscript: @escaping (String) -> Void) async {
        guard !isListening && !isFinishingRecognition else { return }
        errorMessage = nil
        stopSpeaking()

        guard let speechRecognizer else {
            errorMessage = "Speech recognition is unavailable for this language."
            return
        }

        let speechAuthorization = await requestSpeechAuthorization()
        guard speechAuthorization == .authorized else {
            errorMessage = "Allow Speech Recognition in Settings to use voice input."
            return
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard microphoneAuthorized else {
            errorMessage = "Allow microphone access in Settings to use voice input."
            return
        }

        guard speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is temporarily unavailable."
            return
        }
        guard speechRecognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device speech recognition is unavailable for this language."
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            recognitionRequest = request
            self.onTranscript = onTranscript

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            isListening = true
            try audioEngine.start()

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let recognitionError = error?.localizedDescription

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let transcript {
                        self.onTranscript?(transcript)
                    }
                    if let recognitionError {
                        self.stopListening()
                        self.finishRecognition()
                        self.errorMessage = recognitionError
                    } else if isFinal {
                        self.stopListening()
                        self.finishRecognition()
                    }
                }
            }
        } catch {
            stopListening()
            errorMessage = "Couldn't start voice input: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        guard isListening else { return }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        isListening = false
        isFinishingRecognition = recognitionTask != nil
        if !isFinishingRecognition {
            finishRecognition()
        }
        deactivateAudioSession()
    }

    func speak(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stopListening()
        stopSpeaking()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start spoken playback: \(error.localizedDescription)"
            return
        }

        errorMessage = nil
        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        currentUtterance = utterance
        speechSynthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        guard speechSynthesizer.isSpeaking else {
            currentUtterance = nil
            isSpeaking = false
            return
        }

        speechSynthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
        isSpeaking = false
        deactivateAudioSession()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  let currentUtterance = self.currentUtterance,
                  ObjectIdentifier(currentUtterance) == utteranceIdentifier
            else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.deactivateAudioSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  let currentUtterance = self.currentUtterance,
                  ObjectIdentifier(currentUtterance) == utteranceIdentifier
            else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.deactivateAudioSession()
        }
    }

    private func finishRecognition() {
        recognitionRequest = nil
        recognitionTask = nil
        onTranscript = nil
        isFinishingRecognition = false
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't release the audio session: \(error.localizedDescription)"
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
