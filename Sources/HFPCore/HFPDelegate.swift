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
import IOBluetooth
import Shared

/// Delegate that receives IOBluetoothHandsFreeDevice callbacks and forwards them as HFPEvents
public final class HFPDelegate: NSObject, IOBluetoothHandsFreeDeviceDelegate, @unchecked Sendable {
    private let eventStream: HFPEventStream
    private let logger = PhoneBTLogger(category: .hfp)
    private let callStateLock = NSLock()
    private var callSetupState = 0
    private var callIndicatorActive = false
    private var hasObservedCallLifecycle = false
    private var setupEndWorkItem: DispatchWorkItem?

    public init(eventStream: HFPEventStream) {
        self.eventStream = eventStream
        super.init()
    }

    // MARK: - Connection

    public func handsFree(_ device: IOBluetoothHandsFree!,
                          connected status: NSNumber!) {
        // status is an IOReturn code: 0 (kIOReturnSuccess) means connected
        let statusCode = status?.intValue ?? -1
        let isConnected = (statusCode == 0) || (device?.isConnected ?? false)
        logger.info("Delegate: connected callback, status=\(statusCode), isConnected=\(isConnected)")
        if isConnected {
            eventStream.emit(.connected)
        } else {
            eventStream.emit(.connectFailed(
                BluetoothError.connectionFailed("Connection failed with status \(statusCode)")
            ))
        }
    }

    public func handsFree(_ device: IOBluetoothHandsFree!,
                          disconnected status: NSNumber!) {
        let statusCode = status?.intValue ?? -1
        logger.info("Delegate: disconnected, status=\(statusCode)")
        resetCallTracking()
        eventStream.emit(.disconnected(nil))
    }

    // MARK: - Call State Indicators

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          callSetupMode mode: NSNumber!) {
        let setupState = mode?.intValue ?? 0
        logger.info("Delegate: callSetup = \(setupState)")
        let shouldResolveEndedCall = updateCallSetupTracking(setupState)
        eventStream.emit(.callSetup(setupState))

        switch setupState {
        case 1:
            eventStream.emit(.incomingCall(number: nil))
        case 2:
            eventStream.emit(.callDialing(number: ""))
        case 3:
            eventStream.emit(.callAlerting)
        case 0:
            // The call either connected or the unanswered attempt ended. Give
            // the call indicator a brief chance to report an active call.
            if shouldResolveEndedCall {
                scheduleUnansweredCallResolution()
            }
        default:
            break
        }
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          isCallActive: NSNumber!) {
        let active = isCallActive?.boolValue ?? false
        logger.info("Delegate: callActive = \(active)")
        let shouldEmitCallEnded = updateCallIndicatorTracking(active)
        eventStream.emit(.callIndicator(active))

        if active {
            eventStream.emit(.callActive)
        } else if shouldEmitCallEnded {
            eventStream.emit(.callEnded)
        }
    }

    private func updateCallSetupTracking(_ setupState: Int) -> Bool {
        callStateLock.lock()
        defer { callStateLock.unlock() }

        setupEndWorkItem?.cancel()
        setupEndWorkItem = nil
        let previousSetupState = callSetupState
        callSetupState = setupState
        if (1...3).contains(setupState) {
            hasObservedCallLifecycle = true
        }
        return setupState == 0 &&
            previousSetupState != 0 &&
            hasObservedCallLifecycle &&
            !callIndicatorActive
    }

    private func updateCallIndicatorTracking(_ active: Bool) -> Bool {
        callStateLock.lock()
        defer { callStateLock.unlock() }

        setupEndWorkItem?.cancel()
        setupEndWorkItem = nil
        let wasActive = callIndicatorActive
        callIndicatorActive = active
        if active {
            hasObservedCallLifecycle = true
            return false
        }
        guard hasObservedCallLifecycle,
              wasActive || callSetupState == 0 else { return false }
        hasObservedCallLifecycle = false
        return true
    }

    private func scheduleUnansweredCallResolution() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.resolveUnansweredCallIfNeeded()
        }
        callStateLock.lock()
        setupEndWorkItem = workItem
        callStateLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func resolveUnansweredCallIfNeeded() {
        callStateLock.lock()
        guard callSetupState == 0,
              !callIndicatorActive,
              hasObservedCallLifecycle else {
            callStateLock.unlock()
            return
        }
        hasObservedCallLifecycle = false
        setupEndWorkItem = nil
        callStateLock.unlock()

        logger.info("Delegate: call setup ended without becoming active")
        eventStream.emit(.callEnded)
    }

    private func resetCallTracking() {
        callStateLock.lock()
        setupEndWorkItem?.cancel()
        setupEndWorkItem = nil
        callSetupState = 0
        callIndicatorActive = false
        hasObservedCallLifecycle = false
        callStateLock.unlock()
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          callHoldState state: NSNumber!) {
        let held = state?.intValue ?? 0
        logger.info("Delegate: callHeld = \(held)")
        eventStream.emit(.callHeldIndicator(held))

        if held > 0 {
            eventStream.emit(.callHeld)
        }
    }

    // MARK: - Phone Status Indicators

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          signalStrength: NSNumber!) {
        eventStream.emit(.signalStrength(signalStrength?.intValue ?? 0))
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          batteryCharge: NSNumber!) {
        eventStream.emit(.batteryLevel(batteryCharge?.intValue ?? 0))
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          isServiceAvailable: NSNumber!) {
        eventStream.emit(.serviceAvailable(isServiceAvailable?.boolValue ?? false))
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          isRoaming: NSNumber!) {
        eventStream.emit(.roaming(isRoaming?.boolValue ?? false))
    }

    // MARK: - Caller ID

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!,
                          incomingCallFrom number: String!) {
        let num = number ?? "unknown"
        logger.info("Delegate: incoming call from \(num)")
        eventStream.emit(.callerID(number: num, name: nil))
        eventStream.emit(.incomingCall(number: num))
    }

    // MARK: - SCO Audio

    public func handsFree(_ device: IOBluetoothHandsFree!,
                          scoConnectionOpened status: NSNumber!) {
        logger.info("Delegate: SCO opened, status=\(status ?? 0)")
        eventStream.emit(.scoConnected)
    }

    public func handsFree(_ device: IOBluetoothHandsFree!,
                          scoConnectionClosed status: NSNumber!) {
        logger.info("Delegate: SCO closed, status=\(status ?? 0)")
        eventStream.emit(.scoDisconnected)
    }
}
