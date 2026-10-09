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

import Foundation

public enum VoiceGender: String, Codable, Sendable {
    case female
    case male
}

public struct InputConfiguration: Codable, Sendable {
    public let name: String
    public let dateOfBirth: String
    public let insurance: String
    public let additionalDetails: String
    public let gender: VoiceGender?
    public let language: String?
    public let telephoneNumber: String?
    public let doctorReferralDetails: [String: String]?

    public init(
        name: String,
        dateOfBirth: String,
        insurance: String,
        additionalDetails: String,
        gender: VoiceGender? = nil,
        language: String? = nil,
        telephoneNumber: String? = nil,
        doctorReferralDetails: [String: String]? = nil
    ) {
        self.name = name
        self.dateOfBirth = dateOfBirth
        self.insurance = insurance
        self.additionalDetails = additionalDetails
        self.gender = gender
        self.language = language
        self.telephoneNumber = telephoneNumber
        self.doctorReferralDetails = doctorReferralDetails
    }

    var liveVoice: String {
        switch gender {
        case .male:
            return "cedar"
        case .female, nil:
            return "marin"
        }
    }

    var spokenLanguage: String {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty else { return "English" }
        return language
    }
}

struct AppointmentResult: Codable {
    let status: String
    let appointmentDate: String?
    let appointmentTime: String?
    let practice: String?
    let notes: String?
}
