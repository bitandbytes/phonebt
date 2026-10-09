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

@testable import AgentBridge
import Foundation
import Testing

@Test func inputConfigurationDecodesFromJSON() throws {
    let data = Data(#"{"name":"Jane Doe","dateOfBirth":"1990-05-20","insurance":"Example Health","additionalDetails":"Morning preferred","gender":"female","language":"German"}"#.utf8)
    let configuration = try JSONDecoder().decode(InputConfiguration.self, from: data)

    #expect(configuration.name == "Jane Doe")
    #expect(configuration.insurance == "Example Health")
    #expect(configuration.additionalDetails == "Morning preferred")
    #expect(configuration.gender == .female)
    #expect(configuration.liveVoice == "marin")
    #expect(configuration.spokenLanguage == "German")
}

@Test func maleGenderSelectsCedarVoice() throws {
    let data = Data(#"{"name":"John Doe","dateOfBirth":"1990-05-20","insurance":"Example Health","additionalDetails":"Morning preferred","gender":"male"}"#.utf8)
    let configuration = try JSONDecoder().decode(InputConfiguration.self, from: data)

    #expect(configuration.liveVoice == "cedar")
}

@Test func omittedGenderKeepsMarinDefault() throws {
    let data = Data(#"{"name":"Jane Doe","dateOfBirth":"1990-05-20","insurance":"Example Health","additionalDetails":"Morning preferred"}"#.utf8)
    let configuration = try JSONDecoder().decode(InputConfiguration.self, from: data)

    #expect(configuration.gender == nil)
    #expect(configuration.liveVoice == "marin")
    #expect(configuration.spokenLanguage == "English")
}

@Test func doctorReferralDetailsSurviveDecodingAndEncoding() throws {
    let data = Data(#"{"name":"Hasini Jayathilaka","dateOfBirth":"1993-09-01","insurance":"TK","additionalDetails":"Mammography appointment","telephoneNumber":"+491772635867","doctorReferralDetails":{"Überweisung":"Radiologie","Diagnose/Verdachtsdiagnose":"Mastodynie links, Beschwerden zunehmen","Auftrag":"Erbitte MammaSono bds., ggf. Mammographie"}}"#.utf8)
    let configuration = try JSONDecoder().decode(InputConfiguration.self, from: data)

    #expect(configuration.telephoneNumber == "+491772635867")
    #expect(configuration.doctorReferralDetails?["Überweisung"] == "Radiologie")
    #expect(
        configuration.doctorReferralDetails?["Diagnose/Verdachtsdiagnose"] ==
            "Mastodynie links, Beschwerden zunehmen"
    )

    let encoded = try JSONEncoder().encode(configuration)
    let encodedObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let encodedReferral = try #require(
        encodedObject["doctorReferralDetails"] as? [String: String]
    )
    #expect(encodedObject["telephoneNumber"] as? String == "+491772635867")
    #expect(encodedReferral["Auftrag"] == "Erbitte MammaSono bds., ggf. Mammographie")
}
