// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import AppKit
import Metal
import MetalKit
import simd

/// The Immersive visualizer family: scenes that are simulated or raymarched
/// on the GPU instead of drawn from CPU geometry. `VisualizerRenderer` owns
/// one of these, calls `update` before its scene pass (compute work and
/// offscreen passes) and `draw` inside it, and then runs its usual bloom and
/// tone map over the result.
enum ImmersiveKind {
    /// A million particles riding a shell, stirred by a flow field.
    case murmuration
    /// An accretion disk with jets on the beat.
    case singularity
    /// Tracers in a strange attractor (Thomas, Lorenz or Halvorsen by seed).
    case attractor
    /// Fluid simulation: a ring of jets, one per band.
    case liquid
    /// Fluid simulation: jets along the bottom edge.
    case plume
    /// A flight through stars and galaxies.
    case deepField
    /// Raymarched fractal lattice.
    case cathedral

    var isParticles: Bool { self == .murmuration || self == .singularity || self == .attractor }
    var isFluid: Bool { self == .liquid || self == .plume }
    var isRaymarched: Bool { self == .deepField || self == .cathedral }

    /// Rows the offscreen scenes are rendered at before being scaled up to
    /// the window. Cathedral is soft enough not to need more, and a 4K
    /// window at full size would not hold 60 fps; Deep Field is cheap and
    /// its stars are a pixel wide, so it gets more.
    var maxRows: Int { self == .deepField ? 810 : 720 }
}

/// What the scenes need from the audio, already smoothed by the renderer.
struct ImmersiveAudio {
    /// Audio-driven time step; zero in silence.
    var dt: Float
    var bass: Float
    var mid: Float
    var treb: Float
    var level: Float
    var beat: Float
}

/// Matches `SU` in `immersiveShaderSource`: twenty floats, 80-byte stride.
private struct SceneUniforms {
    var time: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treb: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var aspect: Float = 1
    var dt: Float = 0
    var seed: Float = 0
    var hue: Float = 0
    var variant: Float = 0
    var fade: Float = 1
    var travel: Float = 0
    var gridW: Float = 1
    var resX: Float = 1
    var resY: Float = 1
    var gain: Float = 1
    var count: Float = 0
    var gridH: Float = 1
    var dof: Float = 0
}

final class ImmersiveRenderer {
    static let particleCount = 1 << 20

    private let device: MTLDevice
    private let uniformBuffer: MTLBuffer

    private let particleKernel: MTLComputePipelineState
    private let splatKernel: MTLComputePipelineState
    private let advectKernel: MTLComputePipelineState
    private let curlKernel: MTLComputePipelineState
    private let vorticityKernel: MTLComputePipelineState
    private let divergenceKernel: MTLComputePipelineState
    private let pressureKernel: MTLComputePipelineState
    private let gradientKernel: MTLComputePipelineState
    private let dyeKernel: MTLComputePipelineState

    private let splatPipeline: MTLRenderPipelineState
    private let fluidPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let nebulaPipeline: MTLRenderPipelineState
    private let fractalPipeline: MTLRenderPipelineState

    private var particles: MTLBuffer?
    /// Where the particles' light is summed: four `UInt32`s a pixel (the
    /// fourth unused), fixed point. Capped in size and scaled up to the
    /// window, so a 4K window costs no more than a 1080p one.
    private var splatGrid: MTLBuffer?
    private var gridSize = (width: 0, height: 0)
    private static let maxGridRows = 1080

    /// A small random volume, kept for scenes that want noise.
    private let noiseTexture: MTLTexture?
    /// Deep Field's photographs (credits in `docs/deep-field-credits.md`): a
    /// 6 by 4 sheet of galaxies cut from Hubble images, each faded to black
    /// at its rim so it can be added over the sky, and a Hubble deep field
    /// for the far sky. Loaded on first use.
    private var galaxySheet: MTLTexture?
    private var skyTexture: MTLTexture?
    private var photosLoaded = false

    /// Fluid state. Velocity, pressure and dye each ping-pong between two
    /// textures; `scratch` holds the curl and then the divergence.
    private var velocity: [MTLTexture] = []
    private var pressure: [MTLTexture] = []
    private var dye: [MTLTexture] = []
    private var scratch: MTLTexture?
    private var fluidNeedsClear = false

    private var sceneTexture: MTLTexture?

    /// Scene time and distance travelled; both advance only with audio.
    private var time: Float = 0
    private var travel: Float = 0

    private static let format: MTLPixelFormat = .rgba16Float

    init?(device: MTLDevice) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: immersiveShaderSource, options: nil)
        } catch {
            NSLog("Immersive shaders failed to compile: %@", String(describing: error))
            return nil
        }

        func kernel(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else {
                NSLog("Immersive kernel missing: %@", name)
                return nil
            }
            do {
                return try device.makeComputePipelineState(function: fn)
            } catch {
                NSLog("Immersive kernel %@ failed: %@", name, String(describing: error))
                return nil
            }
        }

        enum Blend { case none, alpha, additive }
        func pipeline(_ vertex: String, _ fragment: String, blend: Blend) -> MTLRenderPipelineState? {
            guard let v = library.makeFunction(name: vertex),
                  let f = library.makeFunction(name: fragment) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = v
            desc.fragmentFunction = f
            guard let attachment = desc.colorAttachments[0] else { return nil }
            attachment.pixelFormat = Self.format
            if blend != .none {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha
                let dst: MTLBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                attachment.destinationRGBBlendFactor = dst
                attachment.destinationAlphaBlendFactor = dst
            }
            do {
                return try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("Immersive pipeline %@ failed: %@", fragment, String(describing: error))
                return nil
            }
        }

        guard let uniforms = device.makeBuffer(length: MemoryLayout<SceneUniforms>.stride, options: .storageModeShared),
              let particleKernel = kernel("k_particles"),
              let splatKernel = kernel("k_splat"),
              let advectKernel = kernel("k_fluid_advect"),
              let curlKernel = kernel("k_fluid_curl"),
              let vorticityKernel = kernel("k_fluid_vorticity"),
              let divergenceKernel = kernel("k_fluid_divergence"),
              let pressureKernel = kernel("k_fluid_pressure"),
              let gradientKernel = kernel("k_fluid_gradient"),
              let dyeKernel = kernel("k_fluid_dye"),
              let splatPipeline = pipeline("v_full", "f_splat", blend: .additive),
              let fluidPipeline = pipeline("v_full", "f_fluid", blend: .alpha),
              let blitPipeline = pipeline("v_full", "f_blit", blend: .alpha),
              let nebulaPipeline = pipeline("v_full", "f_nebula", blend: .none),
              let fractalPipeline = pipeline("v_full", "f_fractal", blend: .none)
        else { return nil }

        self.device = device
        uniformBuffer = uniforms
        self.particleKernel = particleKernel
        self.splatKernel = splatKernel
        self.advectKernel = advectKernel
        self.curlKernel = curlKernel
        self.vorticityKernel = vorticityKernel
        self.divergenceKernel = divergenceKernel
        self.pressureKernel = pressureKernel
        self.gradientKernel = gradientKernel
        self.dyeKernel = dyeKernel
        self.splatPipeline = splatPipeline

        // A fixed seed, so every renderer (and every launch) flies through
        // the same cloud.
        let side = 64
        let noiseDesc = MTLTextureDescriptor()
        noiseDesc.textureType = .type3D
        noiseDesc.pixelFormat = .r8Unorm
        noiseDesc.width = side
        noiseDesc.height = side
        noiseDesc.depth = side
        noiseDesc.usage = [.shaderRead]
        noiseTexture = device.makeTexture(descriptor: noiseDesc)
        if let noiseTexture {
            var state: UInt32 = 0x9E3779B9
            var bytes = [UInt8](repeating: 0, count: side * side * side)
            for i in bytes.indices {
                state = state &* 1664525 &+ 1013904223
                bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
            }
            noiseTexture.replace(region: MTLRegionMake3D(0, 0, 0, side, side, side), mipmapLevel: 0, slice: 0,
                                 withBytes: bytes, bytesPerRow: side, bytesPerImage: side * side)
        }
        self.fluidPipeline = fluidPipeline
        self.blitPipeline = blitPipeline
        self.nebulaPipeline = nebulaPipeline
        self.fractalPipeline = fractalPipeline
    }

    // MARK: Per frame

    /// Advances the scene and does everything that has to happen outside the
    /// renderer's scene pass: the simulation kernels and, for the raymarched
    /// scenes, the picture itself at a capped size.
    func update(kind: ImmersiveKind, seed: Float, hue: Float, fade: Float, audio: ImmersiveAudio,
                size: CGSize, spectrum: MTLBuffer, commandBuffer: MTLCommandBuffer) {
        let dt = min(0.05, max(0, audio.dt))
        time += dt
        travel += dt * (0.55 + 1.5 * audio.bass + 0.6 * audio.level)

        var u = SceneUniforms()
        u.time = time
        u.bass = audio.bass
        u.mid = audio.mid
        u.treb = audio.treb
        u.level = audio.level
        u.beat = audio.beat
        u.aspect = Float(size.width / max(1, size.height))
        u.dt = dt
        u.seed = seed
        u.hue = hue
        u.fade = fade
        u.travel = travel
        u.resX = Float(size.width)
        u.resY = Float(size.height)
        u.count = Float(Self.particleCount)

        if kind.isParticles {
            let scale = min(1, CGFloat(Self.maxGridRows) / max(1, size.height))
            gridSize = (max(16, Int(size.width * scale)), max(16, Int(size.height * scale)))
            u.gridW = Float(gridSize.width)
            u.gridH = Float(gridSize.height)
        }
        // More pixels share the same particles: keep the brightness per area.
        let density = (u.gridH / 720) * (u.gridH / 720)

        switch kind {
        case .murmuration: u.variant = 0; u.gain = 0.030 * density; u.dof = 0.0035
        case .singularity: u.variant = 1; u.gain = 0.034 * density; u.dof = 0.0035
        case .attractor:
            // The seed picks the system, so one mode holds three presets.
            u.variant = seed < 0.34 ? 2 : (seed < 0.67 ? 3 : 4)
            u.gain = 0.020 * density
            u.dof = 0.004
        case .liquid: u.variant = 0
        case .plume: u.variant = 1
        case .deepField, .cathedral: break
        }
        uniformBuffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<SceneUniforms>.stride)

        if kind.isParticles {
            stepParticles(spectrum: spectrum, commandBuffer: commandBuffer)
        } else if kind.isFluid {
            stepFluid(aspect: u.aspect, dt: dt, spectrum: spectrum, commandBuffer: commandBuffer)
        } else {
            renderScene(kind: kind, size: size, spectrum: spectrum, commandBuffer: commandBuffer)
        }
    }

    /// Draws the scene into the renderer's scene pass.
    func draw(kind: ImmersiveKind, encoder: MTLRenderCommandEncoder) {
        if kind.isParticles {
            guard let splatGrid else { return }
            encoder.setRenderPipelineState(splatPipeline)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(splatGrid, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else if kind.isFluid {
            guard dye.count == 2 else { return }
            encoder.setRenderPipelineState(fluidPipeline)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(dye[0], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            guard let sceneTexture else { return }
            encoder.setRenderPipelineState(blitPipeline)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(sceneTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    // MARK: Particles

    private func stepParticles(spectrum: MTLBuffer, commandBuffer: MTLCommandBuffer) {
        if particles == nil {
            // Zeroed: every particle starts dead and is placed by the kernel.
            let length = Self.particleCount * MemoryLayout<SIMD4<Float>>.stride * 2
            particles = device.makeBuffer(length: length, options: .storageModeShared)
            if let particles { memset(particles.contents(), 0, length) }
        }
        let gridLength = gridSize.width * gridSize.height * 4 * MemoryLayout<UInt32>.stride
        if splatGrid?.length != gridLength {
            splatGrid = device.makeBuffer(length: gridLength, options: .storageModePrivate)
        }
        guard let particles, let splatGrid else { return }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: splatGrid, range: 0..<gridLength, value: 0)
            blit.endEncoding()
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let count = MTLSize(width: Self.particleCount, height: 1, depth: 1)
        encoder.setComputePipelineState(particleKernel)
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setBuffer(spectrum, offset: 0, index: 2)
        encoder.dispatchThreads(count, threadsPerThreadgroup:
            MTLSize(width: particleKernel.threadExecutionWidth, height: 1, depth: 1))
        encoder.setComputePipelineState(splatKernel)
        encoder.setBuffer(splatGrid, offset: 0, index: 2)
        encoder.dispatchThreads(count, threadsPerThreadgroup:
            MTLSize(width: splatKernel.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
    }

    // MARK: Fluid

    private func texture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.format, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func ensureFluid(aspect: Float) -> Bool {
        let simHeight = 288
        let simWidth = max(64, min(1024, Int((Float(simHeight) * aspect).rounded())))
        if velocity.count == 2, velocity[0].width == simWidth { return true }
        let dyeHeight = 720
        let dyeWidth = max(128, min(2560, Int((Float(dyeHeight) * aspect).rounded())))
        let sim = (0..<5).compactMap { _ in texture(width: simWidth, height: simHeight) }
        let ink = (0..<2).compactMap { _ in texture(width: dyeWidth, height: dyeHeight) }
        guard sim.count == 5, ink.count == 2 else { return false }
        velocity = [sim[0], sim[1]]
        pressure = [sim[2], sim[3]]
        scratch = sim[4]
        dye = ink
        fluidNeedsClear = true
        return true
    }

    private func run(_ kernel: MTLComputePipelineState, _ encoder: MTLComputeCommandEncoder,
                     textures: [MTLTexture], buffers: [MTLBuffer] = []) {
        guard let target = textures.last else { return }
        encoder.setComputePipelineState(kernel)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        let w = kernel.threadExecutionWidth
        let h = max(1, kernel.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func stepFluid(aspect: Float, dt: Float, spectrum: MTLBuffer, commandBuffer: MTLCommandBuffer) {
        guard ensureFluid(aspect: aspect), let scratch else { return }

        if fluidNeedsClear {
            // New textures hold whatever was in that memory.
            for target in velocity + pressure + dye + [scratch] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            fluidNeedsClear = false
        }

        // Silence: nothing is stepped, so the picture holds exactly.
        guard dt > 1e-5, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let buffers = [uniformBuffer, spectrum]

        run(advectKernel, encoder, textures: [velocity[0], velocity[1]], buffers: buffers)
        run(curlKernel, encoder, textures: [velocity[1], scratch])
        run(vorticityKernel, encoder, textures: [velocity[1], scratch, velocity[0]], buffers: [uniformBuffer])
        run(divergenceKernel, encoder, textures: [velocity[0], scratch])
        // The last frame's pressure is a good first guess, so few passes do.
        for _ in 0..<22 {
            run(pressureKernel, encoder, textures: [pressure[0], scratch, pressure[1]])
            pressure.swapAt(0, 1)
        }
        run(gradientKernel, encoder, textures: [velocity[0], pressure[0], velocity[1]])
        velocity.swapAt(0, 1)
        run(dyeKernel, encoder, textures: [velocity[0], dye[0], dye[1]], buffers: buffers)
        dye.swapAt(0, 1)
        encoder.endEncoding()
    }

    // MARK: Raymarched scenes

    private func renderScene(kind: ImmersiveKind, size: CGSize, spectrum: MTLBuffer,
                             commandBuffer: MTLCommandBuffer) {
        let scale = min(1, CGFloat(kind.maxRows) / max(1, size.height))
        let width = max(16, Int(size.width * scale))
        let height = max(16, Int(size.height * scale))
        if sceneTexture?.width != width || sceneTexture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.format, width: width, height: height, mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            sceneTexture = device.makeTexture(descriptor: desc)
        }
        guard let sceneTexture else { return }
        if kind == .deepField, !photosLoaded {
            photosLoaded = true
            let loader = MTKTextureLoader(device: device)
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: true, .generateMipmaps: true,
                .textureStorageMode: MTLStorageMode.private.rawValue
            ]
            func load(_ name: String) -> MTLTexture? {
                guard let data = NSDataAsset(name: name)?.data else {
                    NSLog("Deep Field image missing: %@", name)
                    return nil
                }
                return try? loader.newTexture(data: data, options: options)
            }
            galaxySheet = load("DeepFieldGalaxies")
            skyTexture = load("DeepFieldSky")
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(kind == .deepField ? nebulaPipeline : fractalPipeline)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(spectrum, offset: 0, index: 1)
        encoder.setFragmentTexture(noiseTexture, index: 0)
        if kind == .deepField {
            encoder.setFragmentTexture(galaxySheet, index: 1)
            encoder.setFragmentTexture(skyTexture, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
