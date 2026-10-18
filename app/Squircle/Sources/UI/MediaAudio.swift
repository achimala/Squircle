import AVKit

/// Squircle's videos never take the phone's audio by themselves (user,
/// 2026-10-18): they play muted in an `.ambient` session, which mixes with
/// whatever else is playing, and take audio only while a video the user
/// unmuted is playing. In the overlay the session is the host app's, so it is
/// never touched there.
@MainActor
enum MediaAudio {
    /// The user's last choice in a full-screen player, for this launch.
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

/// A recording full screen. It opens muted unless the user unmuted one
/// earlier this launch, and holds the audio only while unmuted and playing.
final class VideoPlayerViewController: AVPlayerViewController {
    private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        super.init(nibName: nil, bundle: nil)
        let player = AVPlayer(url: url)
        player.isMuted = !MediaAudio.unmuted
        self.player = player
        let changed: @Sendable (AVPlayer) -> Void = { [weak self] _ in Task { @MainActor in self?.sync() } }
        observations = [player.observe(\.isMuted) { player, _ in changed(player) },
                        player.observe(\.timeControlStatus) { player, _ in changed(player) }]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sync()
        player?.play()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.pause()
        sync()
    }

    private func sync() {
        guard let player else { MediaAudio.play(audible: false); return }
        if viewIfLoaded?.window != nil { MediaAudio.unmuted = !player.isMuted }
        MediaAudio.play(audible: viewIfLoaded?.window != nil && !player.isMuted && player.timeControlStatus != .paused)
    }
}
