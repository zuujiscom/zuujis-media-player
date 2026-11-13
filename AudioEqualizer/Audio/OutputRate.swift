// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreAudio

/// The default output device's nominal sample rate, read and set through Core
/// Audio. The file player uses it to match the device to each track, so the
/// mixer has nothing to resample.
///
/// Never used while the system route is running: that route's aggregate device
/// and tap are built for one rate, and changing it underneath them would
/// silence the output (see the tap-lifetime rules in AGENTS.md).
enum OutputRate {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func nominalRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    /// The ranges the device accepts. Most devices list discrete rates as
    /// zero-width ranges; some list a continuous span.
    static func supportedRanges(of device: AudioDeviceID) -> [ClosedRange<Double>] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values.map { $0.mMinimum...max($0.mMinimum, $0.mMaximum) }
    }

    /// The rate to run the device at for a file: the file's own rate when the
    /// device takes it, otherwise the lowest integer multiple of it that the
    /// device takes (an exact upsample, nothing fractional), otherwise nil —
    /// leave the device alone and let the mixer convert.
    static func bestRate(for fileRate: Double, in ranges: [ClosedRange<Double>]) -> Double? {
        guard fileRate > 0 else { return nil }
        for multiple in 1...8 {
            let candidate = fileRate * Double(multiple)
            if ranges.contains(where: { $0.contains(candidate) }) { return candidate }
        }
        return nil
    }

    @discardableResult
    static func setNominalRate(_ rate: Double, of device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }
}
