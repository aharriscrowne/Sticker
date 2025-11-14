#if canImport(UIKit) && !os(watchOS)
import UIKit
import Metal
import MetalKit
import simd
import CoreMotion

public final class StickerFoilView: MTKView {

    public enum MotionEffect {
        case identity
        case accelerometer
        case drag
        case pointer
    }

    // MARK: - Public API (what you’ll wrap in UIViewRepresentable)

    public var image: UIImage? {
        didSet { updateTexture() }
    }

    /// Maps to `offset` in the Metal uniforms (use for motion / tilt).
    public var offset: SIMD2<Float> = .zero {
        didSet {
            needsUniformUpdate = true
            applyTiltFromOffset()
        }
    }

    public var scale: Float = 3.0       { didSet { needsUniformUpdate = true } }
    public var intensity: Float = 0.8   { didSet { needsUniformUpdate = true } }
    public var contrast: Float = 0.9    { didSet { needsUniformUpdate = true } }
    public var blendFactor: Float = 0.6 { didSet { needsUniformUpdate = true } }

    public var checkerScale: Float = 5.0        { didSet { needsUniformUpdate = true } }
    public var checkerIntensity: Float = 1.2    { didSet { needsUniformUpdate = true } }

    public var noiseScale: Float = 100.0        { didSet { needsUniformUpdate = true } }
    public var noiseIntensity: Float = 1.2      { didSet { needsUniformUpdate = true } }

    /// 0 = diamond, 1 = square (matches patternType in the shader).
    public var patternType: Float = 0           { didSet { needsUniformUpdate = true } }

    public var reflectionPosition: SIMD2<Float> = SIMD2(0.2, 0.2) { didSet { needsUniformUpdate = true } }
    /// The maximum intensity to use while the hotspot is active (dragging / pointer over view).
    public var reflectionBaseIntensity: Float = 0.8 {
        didSet {
            if isHighlightActive {
                reflectionIntensity = reflectionBaseIntensity
            }
        }
    }
    /// The currently applied intensity that gets sent to the shader.
    public var reflectionIntensity: Float = 0.0 { didSet { needsUniformUpdate = true } }
    private var reflectionSize: Float = 0.4     { didSet { needsUniformUpdate = true } }

    /// Controls how the offset is driven: by device motion, drag, pointer, or not at all.
    public var motionEffect: MotionEffect = .identity {
        didSet { configureMotionEffect() }
    }

    // MARK: - Metal resources

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var texture: MTLTexture?

    private var needsUniformUpdate = true

    // MARK: - Motion & interaction state

    /// True while the user is actively interacting in a way that should show the hotspot.
    private var isHighlightActive = false
    private let motionManager = CMMotionManager()
    private var panGesture: UIPanGestureRecognizer?
    @available(iOS 13.4, tvOS 13.4, *)
    private var pointerInteraction: UIPointerInteraction?

    // Must match FoilUniforms in StickerShaderUIKit.metal
    struct FoilUniforms {
        var size: SIMD2<Float>
        var offset: SIMD2<Float>
        var scale: Float
        var intensity: Float
        var contrast: Float
        var blendFactor: Float
        var checkerScale: Float
        var checkerIntensity: Float
        var noiseScale: Float
        var noiseIntensity: Float
        var patternType: Float
        var reflectionPosition: SIMD2<Float>
        var reflectionSize: Float
        var reflectionIntensity: Float
    }

    // MARK: - Init

    public override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        super.init(frame: frame, device: dev)
        commonInit(device: dev)
    }

    required init(coder: NSCoder) {
        let dev = MTLCreateSystemDefaultDevice()!
        super.init(coder: coder)
        self.device = dev
        commonInit(device: dev)
    }

    private func commonInit(device: MTLDevice) {
        framebufferOnly = false
        isPaused = false
        enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm

        // Render at device scale and allow transparency so it matches the SwiftUI version
        isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        contentScaleFactor = UIScreen.main.scale

        isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.isEnabled = false
        addGestureRecognizer(pan)
        panGesture = pan

        if #available(iOS 13.4, tvOS 13.4, *) {
            let interaction = UIPointerInteraction(delegate: self)
            addInteraction(interaction)
            pointerInteraction = interaction
        }

        delegate = self

        commandQueue = device.makeCommandQueue()
        setupPipeline(device: device)
        setupVertices(device: device)
        setupUniformBuffer(device: device)
    }

    private func setupPipeline(device: MTLDevice) {
        let library: MTLLibrary

        do {
            if #available(iOS 16.0, tvOS 16.0, *) {
                // On iOS/tvOS 16+ we can load the default library for this SwiftPM module bundle directly.
                library = try device.makeDefaultLibrary(bundle: .module)
            } else {
                // On iOS/tvOS 15 we load the compiled Metal library manually from the package bundle.
                guard let url = Bundle.module.url(forResource: "default", withExtension: "metallib") else {
                    fatalError("StickerFoilView: could not find default.metallib in Sticker bundle")
                }
                library = try device.makeLibrary(URL: url)
            }
        } catch {
            fatalError("StickerFoilView: unable to create Metal library: \(error)")
        }

        // Names must match the functions in StickerShaderUIKit.metal
        let vertexFunction = library.makeFunction(name: "stickerFoilVertex")!
        let fragmentFunction = library.makeFunction(name: "stickerFoilFragment")!

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        // Describe the layout of our Vertex buffer (position + uv)
        let vertexDescriptor = MTLVertexDescriptor()
        // position (float2) at attribute 0
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // uv (float2) at attribute 1
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        // buffer 0 layout: two float2s per vertex
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        descriptor.vertexDescriptor = vertexDescriptor

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("StickerFoilView: failed to create pipeline state: \(error)")
        }
    }

    private func setupVertices(device: MTLDevice) {
        struct Vertex {
            var position: SIMD2<Float>
            var uv: SIMD2<Float>
        }

        // Full-screen quad (triangle strip)
        let vertices: [Vertex] = [
            Vertex(position: [-1, -1], uv: [0, 1]),
            Vertex(position: [ 1, -1], uv: [1, 1]),
            Vertex(position: [-1,  1], uv: [0, 0]),
            Vertex(position: [ 1,  1], uv: [1, 0]),
        ]

        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<Vertex>.stride * vertices.count,
                                         options: [])
    }

    private func setupUniformBuffer(device: MTLDevice) {
        uniformBuffer = device.makeBuffer(length: MemoryLayout<FoilUniforms>.stride,
                                          options: [])
    }

    // MARK: - Texture

    private func updateTexture() {
        guard let device = device,
              let image = image,
              let cgImage = image.cgImage else {
            texture = nil
            return
        }

        let loader = MTKTextureLoader(device: device)
        do {
            texture = try loader.newTexture(cgImage: cgImage,
                                            options: [MTKTextureLoader.Option.SRGB: false])
        } catch {
            print("StickerFoilView: failed to create texture: \(error)")
        }
    }

    // MARK: - Uniforms

    private func writeUniformsIfNeeded() {
        guard needsUniformUpdate,
              let bufferPtr = uniformBuffer?.contents() else { return }

        let size = drawableSize
        var u = FoilUniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            offset: offset,
            scale: scale,
            intensity: intensity,
            contrast: contrast,
            blendFactor: blendFactor,
            checkerScale: checkerScale,
            checkerIntensity: checkerIntensity,
            noiseScale: noiseScale,
            noiseIntensity: noiseIntensity,
            patternType: patternType,
            reflectionPosition: reflectionPosition,
            reflectionSize: reflectionSize,
            reflectionIntensity: reflectionIntensity
        )

        memcpy(bufferPtr, &u, MemoryLayout<FoilUniforms>.stride)
        needsUniformUpdate = false
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Keep drawableSize in sync with the view size at the current scale
        contentScaleFactor = UIScreen.main.scale
        drawableSize = CGSize(width: bounds.width * contentScaleFactor,
                              height: bounds.height * contentScaleFactor)
        reflectionSize = Float(min(bounds.width * contentScaleFactor, (bounds.height * contentScaleFactor) / 2))

        needsUniformUpdate = true
    }

    // MARK: - Motion configuration

    private func configureMotionEffect() {
        // By default, hide the hotspot when switching modes; specific interactions will re-enable it.
        isHighlightActive = false
        reflectionIntensity = 0.0

        switch motionEffect {
        case .identity:
            stopMotionUpdates()
            panGesture?.isEnabled = false
            offset = .zero
        case .accelerometer:
            panGesture?.isEnabled = false
            startMotionUpdates()
        case .drag:
            stopMotionUpdates()
            panGesture?.isEnabled = true
        case .pointer:
            stopMotionUpdates()
            panGesture?.isEnabled = false
            // Pointer updates offset via UIPointerInteractionDelegate callbacks
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion = motion else { return }

            let roll = motion.attitude.roll   // left/right
            let pitch = motion.attitude.pitch // up/down

            let maxOffset: Float = 80.0

            // Same sign convention as your drag code + applyTiltFromOffset
            self.offset = SIMD2<Float>(
                Float(roll)  * maxOffset,   // tilt right -> offset.x > 0
                Float(pitch) * maxOffset    // tilt top toward you -> offset.y > 0
            )
        }
    }

    private func stopMotionUpdates() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            isHighlightActive = true
            reflectionIntensity = reflectionBaseIntensity
            updateOffset(forLocation: location)
        default:
            offset = .zero
            isHighlightActive = false
            reflectionIntensity = 0.0
        }
    }

    private func updateOffset(forLocation location: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Offset in normalized -1...1 space to drive the foil pattern / tilt.
        let nx = (location.x / bounds.width) * 2.0 - 1.0
        let ny = (location.y / bounds.height) * 2.0 - 1.0
        let maxOffset: Float = 80.0
        offset = SIMD2<Float>(Float(nx) * maxOffset,
                              Float(-ny) * maxOffset)

        // Reflection hotspot in 0...1 UV space so the bright area tracks the cursor/finger.
        let u = max(0, min(1, location.x / bounds.width))
        let v = max(0, min(1, location.y / bounds.height))
        // UV space in the shader already uses 0 at top, 1 at bottom
        reflectionPosition = SIMD2<Float>(Float(u), Float(v))    }

    private func applyTiltFromOffset() {
        let maxOffset: Float = 80.0
        let maxAngle: CGFloat = 12.0 * .pi / 180.0

        let normalizedX = CGFloat(offset.x / maxOffset)
        let normalizedY = CGFloat(offset.y / maxOffset)

        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 500.0

        // Flip sign on the X rotation so vertical drag feels correct
        transform = CATransform3DRotate(transform, normalizedY * maxAngle, 1.0, 0.0, 0.0)
        transform = CATransform3DRotate(transform, normalizedX * maxAngle, 0.0, 1.0, 0.0)

        layer.transform = transform
    }

    deinit {
        stopMotionUpdates()
    }
}

// MARK: - MTKViewDelegate

extension StickerFoilView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsUniformUpdate = true
    }

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let commandQueue = commandQueue,
              let texture = texture
        else { return }

        writeUniformsIfNeeded()

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        let sampler = device!.makeSamplerState(descriptor: samplerDescriptor)!
        encoder.setFragmentSamplerState(sampler, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif

@available(iOS 13.4, tvOS 13.4, *)
extension StickerFoilView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   regionFor request: UIPointerRegionRequest,
                                   defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        isHighlightActive = true
        reflectionIntensity = reflectionBaseIntensity
        updateOffset(forLocation: request.location)
        return defaultRegion
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: self)
        return UIPointerStyle(effect: .lift(preview))
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   willExit region: UIPointerRegion,
                                   animator: UIPointerInteractionAnimating) {
        animator.addAnimations {
            self.offset = .zero
            self.isHighlightActive = false
            self.reflectionIntensity = 0.0
        }
    }
}
