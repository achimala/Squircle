import AVKit

/// Squircle's videos never take the phone's audio by themselves (user,
/// 2026-10-18): they play muted in an `.ambient` session, which mixes with
/// whatever else is playing, and take audio only while a video the user
/// unmuted is playing. In the overlay the session is the host app's, so it is
/// never touched there.
@MainActor
enum MediaAudio {
    /// The user's last choice in the media viewer, for this launch.
    static var unmuted = false
    private static var audible = false

    /// At launch: muted playback mixes with other audio.
    static func install() {
        #if !SQUIRCLE_OVERLAY
        apply { try $0.setCategory(.ambient) }
        #if DEBUG
        NSLog("SQUIRCLE-AUDIO installed category=%@", AVAudioSession.sharedInstance().category.rawValue)
        #endif
        #endif
    }

    /// True while a video the user unmuted plays; false gives the audio back.
    static func play(audible wanted: Bool) {
        #if !SQUIRCLE_OVERLAY
        guard wanted != audible else { return }
        audible = wanted
        if wanted {
            apply { try $0.setCategory(.playback, mode: .moviePlayback); try $0.setActive(true) }
        } else {
            apply { try $0.setActive(false, options: .notifyOthersOnDeactivation) }
            apply { try $0.setCategory(.ambient) }
        }
        #if DEBUG
        NSLog("SQUIRCLE-AUDIO audible=%d category=%@", wanted ? 1 : 0, AVAudioSession.sharedInstance().category.rawValue)
        #endif
        #endif
    }

    private static func apply(_ change: (AVAudioSession) throws -> Void) {
        do { try change(.sharedInstance()) } catch {
            #if DEBUG
            NSLog("SQUIRCLE-AUDIO %@", error.localizedDescription)
            #endif
        }
    }
}
