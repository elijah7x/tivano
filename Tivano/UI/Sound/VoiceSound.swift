import AppKit

/// Zeron's call cues; the App supplies its existing sound preference.
@MainActor
enum VoiceSound {
    private static var sounds: [Bool: NSSound] = [:]

    static func play(start: Bool, enabled: Bool) {
        guard enabled, !CaptureRun.isEnabled else { return }
        let sound = sounds[start] ?? {
            let name = start ? "voice-start" : "voice-end"
            let made = Bundle.main.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: true) }
            sounds[start] = made
            return made
        }()
        sounds[!start]?.stop()
        sound?.stop()
        sound?.play()
    }
}
