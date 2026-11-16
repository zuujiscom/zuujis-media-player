// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox

/// The equalizer as a graph node: `BiquadEQ` inside an in-process audio unit.
/// Both audio paths use one where they used to use `AVAudioUnitEQ`: the file
/// player's engine, and the system route's manual-rendering engine.
///
/// Settings are kept here and handed to the filter whenever the unit is
/// (re)allocated, so they can be set before the node is in a graph. The band
/// count is whatever the last `set(bands:)` carried; a new count needs no new
/// node. Main actor only, like its owners.
final class GraphicEQ {
    let node: AVAudioUnitEffect
    private let unit: EQUnit?

    init() {
        node = EQUnit.makeNode()
        unit = node.auAudioUnit as? EQUnit
        if unit == nil { NSLog("GraphicEQ: the EQ unit did not load; audio will pass unfiltered") }
    }

    /// The compensated bands (`EQResponse.compensated`), not the faders' own.
    func set(bands: [EQBand], bypassed: Bool) {
        unit?.set(bands: bands, bypassed: bypassed)
    }

    /// Preamp in decibels, -96...24.
    var globalGain: Double = 0 {
        didSet { unit?.setGain(decibels: globalGain) }
    }
}

/// See `GraphicEQ`. Registered in-process only: it is not a component other
/// apps can see. The render block follows `LimiterUnit`'s.
final class EQUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7A65_7120,       // 'zeq '
        componentManufacturer: 0x5A75_756A,  // 'Zuuj'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registered: Void = {
        AUAudioUnit.registerSubclass(EQUnit.self, as: componentDescription,
                                     name: "Zuujis: Equalizer", version: 1)
    }()

    static func makeNode() -> AVAudioUnitEffect {
        _ = registered
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// What the render block touches. Set up in `allocateRenderResources`,
    /// while nothing is rendering.
    private final class Kernel: @unchecked Sendable {
        var eq: BiquadEQ?
        var input: AVAudioPCMBuffer?
        /// `input`'s buffer list, fetched once: the getter rewrites the byte
        /// sizes from the buffer's frame length every time it is called.
        var list: UnsafeMutablePointer<AudioBufferList>?
        /// The input buffer's own storage, restored before every pull: the
        /// upstream node may point the list at its buffers instead.
        var own: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        var channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
        var channels = 0
        var capacity: AUAudioFrameCount = 0

        func release() {
            eq = nil
            input = nil
            list = nil
            own?.deallocate()
            own = nil
            channelPointers?.deallocate()
            channelPointers = nil
            channels = 0
            capacity = 0
        }

        deinit { release() }
    }

    private let kernel = Kernel()
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!

    // The settings, kept so a newly allocated filter starts with them.
    private var bands: [EQBand] = []
    private var bypassed = false
    private var gainDB: Double = 0

    func set(bands: [EQBand], bypassed: Bool) {
        self.bands = bands
        self.bypassed = bypassed
        kernel.eq?.set(bands: bands, bypassed: bypassed)
    }

    func setGain(decibels: Double) {
        gainDB = decibels
        kernel.eq?.setGain(decibels: decibels)
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        let format = inputBus.format
        // The filter works on separate float buffers, one per channel, and
        // does not change the channel count or the rate.
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.channelCount == outputBus.format.channelCount,
              format.sampleRate == outputBus.format.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()

        kernel.release()
        let channels = Int(format.channelCount)
        let own = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: channels)
        buffer.frameLength = buffer.frameCapacity
        let rawList = buffer.mutableAudioBufferList
        kernel.list = rawList
        let list = UnsafeMutableAudioBufferListPointer(rawList)
        for c in 0..<channels { own[c] = c < list.count ? list[c].mData : nil }
        kernel.own = own
        kernel.channelPointers = .allocate(capacity: channels)
        kernel.channels = channels
        kernel.capacity = maximumFramesToRender
        kernel.input = buffer

        let eq = BiquadEQ(sampleRate: format.sampleRate, channels: channels,
                          capacity: Int(maximumFramesToRender))
        eq.set(bands: bands, bypassed: bypassed)
        eq.setGain(decibels: gainDB)
        kernel.eq = eq
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        kernel.release()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock, let list = kernel.list, let own = kernel.own,
                  let pointers = kernel.channelPointers else { return kAudioUnitErr_NoConnection }
            guard frameCount <= kernel.capacity else { return kAudioUnitErr_TooManyFramesToProcess }

            let bytes = frameCount * UInt32(MemoryLayout<Float>.size)
            let source = UnsafeMutableAudioBufferListPointer(list)
            let channels = min(kernel.channels, source.count)
            for c in 0..<channels {
                source[c].mData = own[c]
                source[c].mDataByteSize = bytes
            }

            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, list)
            guard status == noErr else { return status }

            // Read the pointers back: the upstream node may have swapped in its own.
            for c in 0..<channels {
                guard let data = source[c].mData else { return kAudioUnitErr_NoConnection }
                pointers[c] = data.assumingMemoryBound(to: Float.self)
            }

            kernel.eq?.process(pointers, channels: channels, frames: Int(frameCount))

            let out = UnsafeMutableAudioBufferListPointer(outputData)
            for c in 0..<min(out.count, channels) {
                if let destination = out[c].mData {
                    if destination != source[c].mData { memcpy(destination, source[c].mData, Int(bytes)) }
                } else {
                    // The host left it to us to supply the buffer.
                    out[c].mData = source[c].mData
                }
                out[c].mDataByteSize = bytes
            }
            return noErr
        }
    }
}
