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

import AgentBridge
import AudioPipeline
import Foundation
import HFPCore
import Shared

let logger = PhoneBTLogger(category: .app)
let callAudioDeviceName = ProcessInfo.processInfo.environment["PHONEBT_AUDIO_DEVICE"] ?? "USB Advanced Audio Device"
let bluetoothManager = BluetoothManager()
let audioRouter = AudioRouter(preferredDeviceName: callAudioDeviceName)

var hfpDevice: HFPDevice?
var discoveredDevices: [DiscoveredDevice] = []
var audioSessionManager: AudioSessionManager?
var realtimeSession: RealtimeCallSession?
var audioStartTask: Task<Void, Never>?
var activeAudioDevice: AudioDeviceInfo?
var isRunning = true
var verboseLogging = ProcessInfo.processInfo.environment["PHONEBT_VERBOSE"] == "1"

func printBanner() {
    print("""

    ╔══════════════════════════════════════╗
    ║          PhoneBT v0.2.0              ║
    ║  Realtime AI Phone Calls for macOS   ║
    ╚══════════════════════════════════════╝
    """)
}

func printHelp() {
    print("""

    Commands:
      paired                         - List paired HFP phones
      scan                           - Scan for Bluetooth devices
      connect <idx>                  - Connect to a listed phone
      devices                        - List CoreAudio devices
      setdevice <idx>                - Select a full-duplex call audio device
      call <number> --config <file>  - Dial using caller details from a JSON file
      hangup                         - End the current call
      status                         - Show connection and call status
      verbose <on|off>               - Show every HFP event in the terminal
      disconnect                     - Disconnect the phone
      help                           - Show this help
      quit                           - Exit PhoneBT
    """)
}

func cleanupCall() {
    audioStartTask?.cancel()
    audioStartTask = nil
    realtimeSession?.close()
    realtimeSession = nil
    audioSessionManager?.stop()
    audioSessionManager = nil
    activeAudioDevice = nil
    audioRouter.restorePreviousRouting()
}

func shutdown() {
    isRunning = false
    cleanupCall()
    hfpDevice?.disconnect()
}

signal(SIGINT) { _ in
    print("\nShutting down...")
    shutdown()
    exit(0)
}

signal(SIGTERM) { _ in
    shutdown()
    exit(0)
}

func printDeviceList(_ devices: [DiscoveredDevice]) {
    guard !devices.isEmpty else {
        print("No devices found.")
        return
    }
    for (index, device) in devices.enumerated() {
        let hfp = device.isHandsFreeGateway ? " [HFP]" : ""
        print("  [\(index)] \(device.name) (\(device.address))\(hfp)")
    }
}

func handlePaired() {
    discoveredDevices = bluetoothManager.getPairedPhones()
    printDeviceList(discoveredDevices)
}

func handleScan() async {
    print("Scanning for Bluetooth devices (10 seconds)...")
    do {
        discoveredDevices = try await bluetoothManager.scanForDevices(duration: 10)
        printDeviceList(discoveredDevices)
    } catch {
        print("Scan failed: \(error.localizedDescription)")
    }
}

func handleConnect(indexText: String) async {
    guard let index = Int(indexText), discoveredDevices.indices.contains(index) else {
        print("Invalid device index. Run 'paired' or 'scan' first.")
        return
    }
    let selected = discoveredDevices[index]
    guard let bluetoothDevice = bluetoothManager.device(forAddress: selected.address),
          let device = HFPDevice(bluetoothDevice: bluetoothDevice) else {
        print("Could not create an HFP connection for \(selected.name).")
        return
    }

    print("Connecting to \(selected.name)...")
    do {
        try await device.connect()
        hfpDevice = device
        let stream = device.eventStream.makeStream()
        Task {
            for await event in stream { handleEvent(event) }
        }
        print("Connected to \(selected.name).")
    } catch {
        print("Connection failed: \(error.localizedDescription)")
    }
}

func handleAudioDevices() {
    let devices = audioRouter.allDevices()
    let selected = audioRouter.callAudioDevice()
    guard !devices.isEmpty else {
        print("No audio devices found.")
        return
    }
    for (index, device) in devices.enumerated() {
        let marker = device.id == selected?.id ? "*" : " "
        let io = device.hasInput && device.hasOutput ? "in/out" : device.hasInput ? "in" : device.hasOutput ? "out" : "-"
        print("  [\(index)] \(marker) \(device.name) [\(device.transportTypeDescription), \(io)]")
    }
}

func handleSetDevice(indexText: String) {
    let devices = audioRouter.allDevices()
    guard let index = Int(indexText), devices.indices.contains(index) else {
        print("Invalid audio device index. Run 'devices' first.")
        return
    }
    let device = devices[index]
    guard device.hasInput && device.hasOutput else {
        print("Select a device that supports both input and output.")
        return
    }
    audioRouter.setPreferredDeviceName(device.name)
    print("Call audio device set to \(device.name).")
}

func parseCallArguments(_ argument: String) -> (number: String, configURL: URL)? {
    let separator = " --config "
    guard let range = argument.range(of: separator) else { return nil }
    let number = argument[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    var path = argument[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    if path.count >= 2, path.first == "\"", path.last == "\"" {
        path.removeFirst()
        path.removeLast()
    }
    guard !number.isEmpty, !path.isEmpty else { return nil }
    let expandedPath = NSString(string: path).expandingTildeInPath
    return (number, URL(fileURLWithPath: expandedPath))
}

func handleCall(argument: String) {
    guard let device = hfpDevice, device.currentState.connection == .connected else {
        print("Connect a phone first.")
        return
    }
    guard audioRouter.callAudioDevice() != nil else {
        print("Select a call audio device with 'devices' and 'setdevice <idx>'.")
        return
    }
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
        print("OPENAI_API_KEY is not set.")
        return
    }
    guard let call = parseCallArguments(argument) else {
        print("Usage: call <number> --config /path/to/call.json")
        return
    }
    guard device.currentState.call == .idle else {
        print("A call is already in progress.")
        return
    }

    let configuration: CallConfiguration
    do {
        let data = try Data(contentsOf: call.configURL)
        configuration = try JSONDecoder().decode(CallConfiguration.self, from: data)
    } catch {
        print("Could not load call configuration: \(error.localizedDescription)")
        return
    }

    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let resultName = "\(call.configURL.deletingPathExtension().lastPathComponent)-\(timestamp)-appointment-result.json"
    let resultURL = call.configURL.deletingLastPathComponent().appendingPathComponent(resultName)
    let session = RealtimeCallSession(
        apiKey: apiKey,
        configuration: configuration,
        resultURL: resultURL,
        device: device
    ) { message in
        print("\n[Realtime] \(message)")
        print("phonebt> ", terminator: "")
        fflush(stdout)
    }
    realtimeSession = session
    session.prepare()

    do {
        try device.dial(number: call.number)
        try? device.transferAudioToComputer()
        print("Dialing \(call.number)… Realtime session is preparing.")
    } catch {
        session.close()
        realtimeSession = nil
        print("Dial failed: \(error.localizedDescription)")
    }
}

func startCallAudioWhenAvailable(attempts: Int = 20) async {
    guard audioSessionManager == nil, let realtimeSession else { return }

    for _ in 0..<attempts {
        if Task.isCancelled { return }
        if let audioDevice = audioRouter.callAudioDevice() {
            _ = audioRouter.routeToCallAudioDevice()
            let manager = AudioSessionManager()
            do {
                try manager.configure(deviceID: audioDevice.id)
                try manager.start()
                try realtimeSession.startAudio(using: manager)
                audioSessionManager = manager
                activeAudioDevice = audioDevice
                print("Realtime audio started on \(audioDevice.name).")
            } catch {
                manager.stop()
                print("Could not start Realtime audio: \(error.localizedDescription)")
            }
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
    print("Call audio device did not become available.")
}

func startCallAudio() {
    guard audioSessionManager == nil, audioStartTask == nil else { return }
    audioStartTask = Task { @MainActor in
        await startCallAudioWhenAvailable()
        audioStartTask = nil
    }
}

func handleEvent(_ event: HFPEvent) {
    if verboseLogging {
        print("\n[HFP] \(String(describing: event))")
    }
    switch event {
    case .callActive:
        print("\nCall active.")
        startCallAudio()
    case .scoConnected:
        if hfpDevice?.currentState.call == .active { startCallAudio() }
    case .callEnded:
        print("\nCall ended.")
        cleanupCall()
    case .scoDisconnected:
        if activeAudioDevice?.isBluetooth == true { cleanupCall() }
    case .disconnected:
        print("\nPhone disconnected.")
        cleanupCall()
        hfpDevice = nil
    case .incomingCall:
        print("\nIncoming calls are not handled by the Realtime agent in this version.")
    default:
        break
    }
}

func handleVerbose(argument: String) {
    switch argument.lowercased() {
    case "on", "1", "true":
        verboseLogging = true
        print("Verbose HFP logging enabled.")
    case "off", "0", "false":
        verboseLogging = false
        print("Verbose HFP logging disabled.")
    default:
        print("Verbose HFP logging is \(verboseLogging ? "on" : "off"). Usage: verbose <on|off>")
    }
}

func handleHangup() {
    guard let device = hfpDevice else {
        print("No phone connected.")
        return
    }
    do {
        try device.endCall()
    } catch {
        print("Hangup failed: \(error.localizedDescription)")
    }
}

func handleStatus() {
    guard let device = hfpDevice else {
        print("Connection: disconnected")
        return
    }
    let state = device.currentState
    print("Connection: \(state.connection.rawValue)")
    print("Call: \(state.call.rawValue)")
    print("HFP audio: \(state.audio.rawValue)")
    print("Realtime: \(realtimeSession == nil ? "inactive" : "prepared")")
    if let call = state.activeCall {
        print("Number: \(call.number ?? "unknown")")
        if let duration = call.durationDescription { print("Duration: \(duration)") }
    }
}

printBanner()
printHelp()

let mainTask = Task {
    while isRunning {
        print("phonebt> ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""

        switch command {
        case "paired": handlePaired()
        case "scan": await handleScan()
        case "connect": await handleConnect(indexText: argument)
        case "devices", "audio": handleAudioDevices()
        case "setdevice": handleSetDevice(indexText: argument)
        case "call", "dial": handleCall(argument: argument)
        case "hangup", "end": handleHangup()
        case "status": handleStatus()
        case "verbose": handleVerbose(argument: argument)
        case "disconnect":
            cleanupCall()
            hfpDevice?.disconnect()
            hfpDevice = nil
        case "help": printHelp()
        case "quit", "exit", "q":
            print("Goodbye!")
            shutdown()
            exit(0)
        default:
            print("Unknown command. Type 'help'.")
        }
    }
}

RunLoop.main.run()
