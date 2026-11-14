import AudioToolbox
import Foundation

/// A short, optional cue for an explicit UI action. It never changes the app's
/// audio session or plays for background work, and is off until the user opts in.
@MainActor
enum InterfaceFeedback {
    static let soundPreferenceKey = "VexSign.interfaceSoundsEnabled"

    static func soundsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: soundPreferenceKey)
    }

    private static let selectionSound: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "interface-feedback", withExtension: "wav") else { return nil }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError else { return nil }
        return sound
    }()

    static func selection() {
        guard soundsEnabled(), let sound = selectionSound else { return }
        AudioServicesPlaySystemSound(sound)
    }
}
