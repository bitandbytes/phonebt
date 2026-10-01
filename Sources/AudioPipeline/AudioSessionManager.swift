// Copyright 2026 ICOA Inc.
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

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Shared

/// Shared AVAudioEngine for full-duplex capture and playback over Bluetooth SCO
public final class AudioSessionManager: @unchecked Sendable {
    public let engine: AVAudioEngine
    public let playerNode: AVAudioPlayerNode
    private let logger = PhoneBTLogger(category: .audio)

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
    }

    /// Configure engine to use specific input/output devices by CoreAudio device ID
    public func configure(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        let inputUnit = engine.inputNode.audioUnit!
        let outputUnit = engine.outputNode.audioUnit!

        try setDevice(inputDeviceID, on: inputUnit)
        try setDevice(outputDeviceID, on: outputUnit)

        // Connect player node to output
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        logger.info("Audio engine configured — input: \(inputDeviceID), output: \(outputDeviceID)")
    }

    /// Configure engine targeting a single full-duplex device for both input and output
    public func configure(deviceID: AudioDeviceID) throws {
        try configure(inputDeviceID: deviceID, outputDeviceID: deviceID)
    }

    /// Configure engine targeting a single device looked up by UID
    public func configure(deviceUID: String) throws {
        guard let device = AudioDeviceManager().getAllDevices().first(where: { $0.uid == deviceUID }) else {
            throw AudioSessionError.deviceNotFound(deviceUID)
        }
        try configure(deviceID: device.id)
    }

    public func start() throws {
        // Enable voice processing for echo cancellation (macOS 14+)
        if #available(macOS 14.0, *) {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                logger.info("Voice processing (AEC) enabled")
            } catch {
                logger.error("Failed to enable voice processing: \(error)")
            }
        }

        try engine.start()
        logger.info("Audio engine started")
    }

    public func stop() {
        playerNode.stop()
        engine.stop()
        logger.info("Audio engine stopped")
    }

    // MARK: - Private

    /// `kAudioOutputUnitProperty_CurrentDevice` takes an `AudioDeviceID`
    /// (passing a UID string fails with kAudioUnitErr_InvalidPropertyValue).
    private func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit) throws {
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioSessionError.deviceConfigFailed(status)
        }
    }
}

public enum AudioSessionError: Error, LocalizedError {
    case deviceConfigFailed(OSStatus)
    case deviceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .deviceConfigFailed(let status):
            return "Failed to configure audio device (OSStatus \(status))"
        case .deviceNotFound(let uid):
            return "Audio device not found: \(uid)"
        }
    }
}
