//
//  BackgroundKeepAlive.swift
//  PosterDrop
//
//  配对阶段保活：用户要切到“设置”输入 PIN，App 不能被挂起。
//  用一路静音音频维持后台运行（Info.plist 已声明 UIBackgroundModes = audio）。
//

import Foundation
import AVFoundation

final class BackgroundKeepAlive {

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?

    func start() {
        guard engine == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                  let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else {
                return
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()

            silence.frameLength = 44100
            player.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
            player.play()

            self.engine = engine
            self.player = player
            self.buffer = silence
        } catch {
            LogBus.shared.append("⚠️ 后台保活启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        buffer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
