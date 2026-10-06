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

/// Protocol for speech-to-text providers.
/// The default conformer is `AudioCapture` (Apple SFSpeechRecognizer).
public protocol STTProvider: AnyObject {
    /// Called with final transcribed text for each utterance.
    var onTranscription: ((String) -> Void)? { get set }

    /// Start capturing and transcribing audio.
    func start() throws

    /// Stop capturing audio.
    func stop()

    /// Request authorization for speech recognition.
    static func requestAuthorization(completion: @escaping (Bool) -> Void)
}
