// Copyright 2026 ICOA Inc.
// Modifications Copyright 2026 Ravindu Kumarasiri.
// Modified from the original PhoneBT project by Ravindu Kumarasiri in 2026.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFoundation
import Foundation
import Shared

/// Converts between the call device's native format and GPT-Live PCM16 audio.
public final class AudioBridge: @unchecked Sendable {
    private struct PlaybackCompletionWaiter {
        let id: UUID
        let completion: @Sendable (Bool) -> Void
    }

    public static let sampleRate = 24_000.0

    private static let inputGateThresholdDBFS = -38.0
    private static let inputGateHangoverSeconds = 0.2

    private let sessionManager: AudioSessionManager
    private let playbackQueue = DispatchQueue(label: "com.phonebt.realtime.playback")
    private let logger = PhoneBTLogger(category: .audio)
    private var isCapturing = false
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration = 0
    private var settleCheckScheduled = false
    private var playbackCompletionWaiters: [PlaybackCompletionWaiter] = []

    public init(sessionManager: AudioSessionManager) {
        self.sessionManager = sessionManager
    }

    public func startCapture(onAudio: @escaping @Sendable (Data) -> Void) throws {
        guard !isCapturing else { return }

        let inputNode = sessionManager.engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info(
            "Realtime capture input format: \(inputFormat.sampleRate) Hz, " +
            "\(inputFormat.channelCount) channel(s), interleaved=\(inputFormat.isInterleaved)"
        )
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let realtimeFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: realtimeFormat) else {
            throw AudioError.unsupportedInputFormat
        }

        let gateThreshold = Int(
            Double(Int16.max) * pow(10, Self.inputGateThresholdDBFS / 20)
        )
        let gateHangoverSamples = Int(Self.sampleRate * Self.inputGateHangoverSeconds)
        var isGateOpen = false
        var remainingHangoverSamples = 0
        var hasLoggedFirstBuffer = false
        var hasLoggedInputSignal = false
        var hasLoggedGateOpening = false
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            let ratio = Self.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio)))
            guard let converted = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: capacity) else { return }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, conversionError == nil,
                  let audioBuffer = converted.audioBufferList.pointee.mBuffers.mData,
                  converted.frameLength > 0 else { return }

            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: audioBuffer, count: byteCount)
            let samples = audioBuffer.assumingMemoryBound(to: Int16.self)
            var peak = 0
            for index in 0..<Int(converted.frameLength) {
                peak = max(peak, abs(Int(samples[index])))
            }
            let peakDBFS = 20 * log10(
                max(Double(peak) / Double(Int16.max), 1 / Double(Int16.max))
            )
            if !hasLoggedFirstBuffer {
                hasLoggedFirstBuffer = true
                self.logger.info(
                    "Realtime capture received first buffer: \(converted.frameLength) frames, " +
                    "peak=\(String(format: "%.1f", peakDBFS)) dBFS"
                )
            }
            if !hasLoggedInputSignal, peak > 100 {
                hasLoggedInputSignal = true
                self.logger.info(
                    "Realtime capture detected input signal: " +
                    "peak=\(String(format: "%.1f", peakDBFS)) dBFS"
                )
            }

            if isGateOpen {
                onAudio(data)
                if peak >= gateThreshold {
                    remainingHangoverSamples = gateHangoverSamples
                } else {
                    remainingHangoverSamples -= Int(converted.frameLength)
                    if remainingHangoverSamples <= 0 {
                        isGateOpen = false
                    }
                }
            } else if peak >= gateThreshold {
                isGateOpen = true
                remainingHangoverSamples = gateHangoverSamples
                if !hasLoggedGateOpening {
                    hasLoggedGateOpening = true
                    self.logger.info(
                        "Realtime input gate opened at " +
                        "\(String(format: "%.1f", peakDBFS)) dBFS"
                    )
                }
                onAudio(data)
            } else {
                onAudio(Data(repeating: 0, count: byteCount))
            }
        }

        isCapturing = true
        logger.info(
            "GPT-Live audio capture started at 24 kHz PCM16 with " +
            "\(Self.inputGateThresholdDBFS) dBFS input gate"
        )
    }

    public func stopCapture() {
        guard isCapturing else { return }
        sessionManager.engine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        logger.info("GPT-Live audio capture stopped")
    }

    public func setInputVolume(decibels: Float32) throws {
        try sessionManager.setInputVolume(decibels: decibels)
    }

    public func play(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        playbackQueue.async { [weak self] in
            self?.schedulePlayback(pcm16Data)
        }
    }

    public func cancelPlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.sessionManager.playerNode.stop()
            self.sessionManager.playerNode.reset()
            self.pendingPlaybackBuffers = 0
            self.finishPlaybackWaiters()
            self.sessionManager.playerNode.play()
        }
    }

    /// Calls `completion` after queued audio plays, or after `maximumWait` if an
    /// AVAudioPlayerNode completion callback is lost. The argument is true on timeout.
    public func whenPlaybackFinishes(
        maximumWait: TimeInterval = 3,
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            let waiter = PlaybackCompletionWaiter(id: UUID(), completion: completion)
            self.playbackCompletionWaiters.append(waiter)
            self.schedulePlaybackSettlementCheckIfNeeded()
            self.playbackQueue.asyncAfter(deadline: .now() + maximumWait) { [weak self] in
                guard let self,
                      let index = self.playbackCompletionWaiters.firstIndex(where: { $0.id == waiter.id }) else {
                    return
                }
                let timedOutWaiter = self.playbackCompletionWaiters.remove(at: index)
                self.logger.error(
                    "Playback drain timed out with \(self.pendingPlaybackBuffers) buffer(s) pending"
                )
                DispatchQueue.global().async {
                    timedOutWaiter.completion(true)
                }
            }
        }
    }

    /// Stops callbacks and drains queued playback work before the audio engine is released.
    public func shutdown() {
        playbackQueue.sync {
            sessionManager.playerNode.stop()
            sessionManager.playerNode.reset()
            pendingPlaybackBuffers = 0
            finishPlaybackWaiters()
        }
        stopCapture()
    }

    private func schedulePlayback(_ data: Data) {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ) else { return }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }

        sourceBuffer.frameLength = frameCount
        guard let destination = sourceBuffer.audioBufferList.pointee.mBuffers.mData else { return }
        data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: data.count)

        let outputFormat = sessionManager.engine.mainMixerNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else { return }
        let ratio = outputFormat.sampleRate / Self.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, ceil(Double(frameCount) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            logger.error("Failed to convert Realtime output audio: \(conversionError?.localizedDescription ?? "unknown error")")
            return
        }

        playbackGeneration += 1
        pendingPlaybackBuffers += 1
        sessionManager.playerNode.scheduleBuffer(
            outputBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.playbackQueue.async { [weak self] in
                guard let self else { return }
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                if self.pendingPlaybackBuffers == 0 {
                    self.schedulePlaybackSettlementCheckIfNeeded()
                }
            }
        }
        if !sessionManager.playerNode.isPlaying {
            sessionManager.playerNode.play()
        }
    }

    private func finishPlaybackWaiters() {
        let waiters = playbackCompletionWaiters
        playbackCompletionWaiters.removeAll()
        for waiter in waiters {
            DispatchQueue.global().async {
                waiter.completion(false)
            }
        }
    }

    /// GPT-Live has no per-utterance audio-done event. Require a short quiet
    /// interval after the local playback queue drains before treating speech as complete.
    private func schedulePlaybackSettlementCheckIfNeeded() {
        guard pendingPlaybackBuffers == 0,
              !playbackCompletionWaiters.isEmpty,
              !settleCheckScheduled else { return }

        settleCheckScheduled = true
        let generation = playbackGeneration
        playbackQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.settleCheckScheduled = false
            guard self.pendingPlaybackBuffers == 0,
                  self.playbackGeneration == generation else {
                self.schedulePlaybackSettlementCheckIfNeeded()
                return
            }
            self.finishPlaybackWaiters()
        }
    }
}

public enum AudioError: Error, LocalizedError {
    case unsupportedInputFormat

    public var errorDescription: String? {
        "The selected call audio device cannot be converted to 24 kHz PCM16."
    }
}
