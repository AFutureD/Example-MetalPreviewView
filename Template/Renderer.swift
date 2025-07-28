//
//  Renderer.swift
//  Template
//
//  Created by Huanan on 2025/7/28.
//

import MetalKit
import CoreMedia
import MetalPerformanceShaders




class Render: NSObject, MTKViewDelegate {
    enum ContentMode : Int, Sendable {
        case scaleAspectFit = 1
        case scaleAspectFill = 2
    }

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?

    var computePipelineState: MTLComputePipelineState?

    var sampleBufferTextureCache: CVMetalTextureCache?
    var sampleBuffer: CMSampleBuffer?

    /// only alpha channel. range 0 - 1.
    /// 0: the sample buffer color
    /// 1: the other color
    var maskTexture: (any MTLTexture)?

    // rect in view bound coordinate.
    // maskRectInViewBounds -> drawable size -> maskTexture.
    var maskRectInViewBounds: CGRect? {
        didSet {
            updateMask()
        }
    }

    // this value will clamp between 0 - maskRectInViewBounds / 2
    var maskCornerRadiusInViewBounds: CGFloat = .zero {
        didSet {
            updateMask()
        }
    }

    var maskImage: UIImage? = nil {
        didSet {
            updateMask()
        }
    }

    var drawableScale: CGFloat = .zero

    var drawableSize: CGSize = .zero {
        didSet {
            if oldValue != drawableSize {
                updateTransform()
                updateMask()
            }
        }
    }

    var sampleBufferAngle: CGFloat = 0 {
        didSet { if oldValue != sampleBufferAngle { updateTransform() }}
    }

    var sampleBufferSize: CGSize = .zero {
        didSet { if oldValue != sampleBufferSize { updateTransform() }}
    }

    var contentMode: ContentMode = .scaleAspectFill {
        didSet { if oldValue != contentMode { updateTransform() }}
    }

    // transfer the drawable's texture gid to buffer's texture coord.
    var textureTransform: CGAffineTransform = .identity

    init(view: MTKView) {
        self.device = view.device
        self.drawableScale = view.contentScaleFactor
        self.commandQueue = view.device?.makeCommandQueue()
        super.init()

        view.framebufferOnly = false

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device!, nil, &sampleBufferTextureCache)
        setupComputePipeline()
    }

    func setupComputePipeline() {
        guard let device = device else { return }

        let library = device.makeDefaultLibrary()
        let kernelFunction = library?.makeFunction(name: "gaussianBlur")

        do {
            computePipelineState = try device.makeComputePipelineState(function: kernelFunction!)
        } catch {
            print("Failed to create compute pipeline state: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard
            let device,
            let sampleBuffer,
            let drawable = view.currentDrawable,
            let commandQueue,
            let sampleBufferTextureCache,
            let pipelineState = computePipelineState
        else {
            return
        }

        assert(drawableSize == view.drawableSize, "Drawable Size Has Changed. Current \(view.drawableSize), but Render still \(drawableSize).")
        assert(view.bounds.width * self.drawableScale == self.drawableSize.width, "Bounds(\(view.bounds)), Scale(\(drawableScale)), Drawable Size(\(drawableSize)) are not match.")

        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var inputTexture: CVMetalTexture?

        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sampleBufferTextureCache,
                                                  pixelBuffer, nil, .bgra8Unorm,
                                                  width, height, 0, &inputTexture)

        guard let inputMTLTexture = CVMetalTextureGetTexture(inputTexture!) else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!

        let blurTextureDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: inputMTLTexture.pixelFormat,
                                                                       width: inputMTLTexture.width,
                                                                       height: inputMTLTexture.height,
                                                                       mipmapped: false)
        blurTextureDesc.usage = [.shaderRead, .shaderWrite]
        guard let blurTexture = device.makeTexture(descriptor: blurTextureDesc) else { return }

        let blurKernel = MPSImageGaussianBlur(device: device, sigma: 20.0)
        blurKernel.edgeMode = .clamp
        blurKernel.encode(commandBuffer: commandBuffer,
                          sourceTexture: inputMTLTexture,
                          destinationTexture: blurTexture)

        var transform = textureTransform.convertToSIMD()

        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(drawable.texture, index: 0)
        computeEncoder.setTexture(inputMTLTexture, index: 1)
        computeEncoder.setTexture(blurTexture, index: 2)
        computeEncoder.setTexture(maskTexture, index: 3)
        computeEncoder.setBytes(&transform, length: MemoryLayout<simd_float3x3>.stride, index: 0)

        // https://developer.apple.com/documentation/metal/calculating-threadgroup-and-grid-sizes#Calculate-Threads-per-Threadgroup
        let tWidth = pipelineState.threadExecutionWidth
        let tHeight = pipelineState.maxTotalThreadsPerThreadgroup / tWidth
        let threadsPerGroup = MTLSizeMake(tWidth, tHeight, 1)
        let dWidth = Int(view.drawableSize.width)
        let dHeight = Int(view.drawableSize.height)
        let threadsPerGrid = MTLSizeMake(dWidth, dHeight, 1)

        if device.supportsFamily(.apple4) {
            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        } else {
            let threadgroupsPerGrid = MTLSize(width:  (threadsPerGrid.width  + threadsPerGroup.width  - 1) / threadsPerGroup.width,
                                              height: (threadsPerGrid.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                              depth:  1)
            computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        }
        computeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension Render {

    func updateTransform() {
        guard sampleBufferSize != .zero, drawableSize != .zero else {
            textureTransform = .identity
            return
        }

        let sampleBufferSize: CGSize = {
            let rect = CGRect(origin: .zero, size: self.sampleBufferSize)
            let rotatedSize = rect.applying(.identity.rotated(by: self.sampleBufferAngle / 180 * .pi)).size
            return CGSize(width: Int(round(rotatedSize.width)), height: Int(round(rotatedSize.height)))
        }()

        let widthScale  = sampleBufferSize.width / drawableSize.width
        let heightScale = sampleBufferSize.height / drawableSize.height

        let scale = switch contentMode {
        case .scaleAspectFit:
            max(widthScale, heightScale)
        case .scaleAspectFill:
            min(widthScale, heightScale)
        }

        let deltaX = (sampleBufferSize.width - drawableSize.width * scale) / 2
        let deltaY = (sampleBufferSize.height - drawableSize.height * scale) / 2

        textureTransform = CGAffineTransform.identity
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: deltaX, y: deltaY)
    }
}


extension Render {
    func updateMask() {
        guard drawableSize != .zero, let device else {
            return
        }

        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return
        }

        let buffer:[UInt8]? = if let maskImage {
            buildImageMask(image: maskImage)
        } else if let rect = maskRectInViewBounds {
            buildRoundedRectangleMask(roundedRect: rect.applying(.identity.scaledBy(x: drawableScale, y: drawableScale)),
                                      cornerRadius: maskCornerRadiusInViewBounds * drawableScale)
        } else {
            nil
        }

        guard let buffer else {
            self.maskTexture = nil
            return
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: buffer, bytesPerRow: width)

        self.maskTexture = texture
    }
}

extension Render {
    /// using MTLPixelFormat.r8Unorm
    static func buildMaskBufferInGraySpace(size: CGSize, drawOnContext: (CGContext, CGSize) -> Void) -> [UInt8]? {
        let start = mach_absolute_time()

        let width = Int(size.width)
        let height = Int(size.height)

        var buffer = [UInt8](repeating: 0, count: width * height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        drawOnContext(context, size)

        let end = mach_absolute_time()
        print("[*]: \(machTimeToSeconds(end - start) * 1000)ms")
        return buffer
    }
}

extension Render {
    // about 5 ms
    func buildRoundedRectangleMask(roundedRect: CGRect, cornerRadius: CGFloat) -> [UInt8]? {
        let buffer = Self.buildMaskBufferInGraySpace(size: drawableSize) { context, size in
            let path = UIBezierPath(roundedRect: roundedRect, cornerRadius: cornerRadius)

            context.addPath(path.cgPath)
            context.setFillColor(gray: 1, alpha: 1) // change gray from 0 - 1
            context.fillPath()
        }
        return buffer
    }

    /// Create a mask from the image's alpha channel.
    ///
    /// This func spend about 70ms.
    ///
    /// Exmaple:
    /// ```Swift
    /// let image = UIGraphicsImageRenderer(size: size).image { rendererCtx in
    ///     let ctx = rendererCtx.cgContext
    ///
    ///     let scaledRect = rect.applying(.identity.scaledBy(x: scale, y: scale))
    ///     let scaledCornerRadius = cornerRadis * scale
    ///
    ///     let path = UIBezierPath(roundedRect: scaledRect, cornerRadius: scaledCornerRadius)
    ///     ctx.addPath(path.cgPath)
    ///
    ///     ctx.setFillColor(gray: 1, alpha: 0.5) // change gray from 0 - 1
    ///     ctx.fillPath()
    /// }
    /// ```
    func buildImageMask(image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else {
            return nil
        }

        let buffer = Self.buildMaskBufferInGraySpace(size: drawableSize) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.draw(cgImage, in: rect) // TODO: Scale the image
        }

        return buffer
    }
}
