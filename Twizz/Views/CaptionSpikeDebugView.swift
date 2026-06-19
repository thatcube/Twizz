import AVFoundation
import SwiftUI

/// EXPERIMENTAL SPIKE harness — drives `LiveCaptionSpike` from a self-contained
/// debug screen so we can prove on-device caption generation works on the Apple
/// TV without any destructive change to the player. Resolves a channel's
/// audio-only HLS playlist, runs on-device speech recognition over it, and shows
/// the recognized text live.
///
/// Gated to tvOS 26+ (the floor for `SpeechAnalyzer`) and surfaced only from a
/// DEBUG-only Settings entry. Not a shipping UI.
@available(tvOS 26.0, *)
@MainActor
@Observable
final class CaptionSpikeController {
    private(set) var status: String = "Idle"
    private(set) var finalizedLines: [String] = []
    private(set) var volatileLine: String = ""
    private(set) var isRunning = false

    private var spike: LiveCaptionSpike?

    func start(channel: String) async {
        guard !isRunning else { return }
        let login = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !login.isEmpty else { return }
        isRunning = true
        finalizedLines = []
        volatileLine = ""
        status = "Resolving \(login)…"

        do {
            LiveCaptionSpike.fileLog("=== spike run for \(login) ===")
            let playback = try await PlaybackService.resolve(for: login)
            guard let audioURL = playback.qualities.first(where: { $0.isAudioOnly })?.url else {
                status = "No audio-only rendition for \(login)."
                LiveCaptionSpike.fileLog("no audio-only rendition for \(login)")
                isRunning = false
                return
            }
            LiveCaptionSpike.fileLog("resolved audio URL ok")
            status = "Loading on-device model…"
            let spike = LiveCaptionSpike(
                playlistURL: audioURL,
                headers: PlaybackService.streamHeaders
            ) { [weak self] transcript in
                Task { @MainActor in self?.apply(transcript) }
            }
            self.spike = spike
            try await spike.start()
            status = "Listening to \(login) — captions below"
            LiveCaptionSpike.fileLog("listening to \(login)")
        } catch {
            status = "Failed: \(error.localizedDescription)"
            LiveCaptionSpike.fileLog("FAILED: \(error)")
            isRunning = false
            spike = nil
        }
    }

    func stop() async {
        await spike?.stop()
        spike = nil
        isRunning = false
        status = "Stopped"
    }

    private func apply(_ transcript: LiveCaptionSpike.Transcript) {
        if transcript.isVolatile {
            volatileLine = transcript.text
        } else {
            finalizedLines.append(transcript.text)
            if finalizedLines.count > 40 {
                finalizedLines.removeFirst(finalizedLines.count - 40)
            }
            volatileLine = ""
        }
    }
}

@available(tvOS 26.0, *)
struct CaptionSpikeDebugView: View {
    var autoStartChannel: String? = nil
    @State private var controller = CaptionSpikeController()
    @State private var channel = "hasanabi"
    @Environment(\.dismiss) private var dismiss

    private let presets = ["hasanabi", "theprimeagen", "xqc", "zackrawrr"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Live Caption Spike")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
                Button("Close") { dismiss() }
            }

            Text(controller.status)
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                TextField("channel", text: $channel)
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 400)
                ForEach(presets, id: \.self) { name in
                    Button(name) { channel = name }
                }
            }

            HStack(spacing: 16) {
                Button(controller.isRunning ? "Restart" : "Start") {
                    Task {
                        await controller.stop()
                        await controller.start(channel: channel)
                    }
                }
                Button("Stop") { Task { await controller.stop() } }
                    .disabled(!controller.isRunning)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(controller.finalizedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !controller.volatileLine.isEmpty {
                        Text(controller.volatileLine)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .onDisappear { Task { await controller.stop() } }
        .task {
            if let autoStartChannel {
                channel = autoStartChannel
                await controller.start(channel: autoStartChannel)
            }
        }
    }
}
