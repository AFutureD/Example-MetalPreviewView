//
//  ViewController.swift
//  Pin
//
//  Created by AFuture on 2023/9/12.
//

import UIKit
import AVFoundation
import MetalKit
import MetalPerformanceShaders
import Combine
import mach

extension CGAffineTransform {
    func convertToSIMD() -> simd_float3x3 {
        return simd_float3x3(
            SIMD3(Float(self.a),  Float(self.b),  0),
            SIMD3(Float(self.c),  Float(self.d),  0),
            SIMD3(Float(self.tx), Float(self.ty), 1)
        )
    }
}

extension CMVideoDimensions {
    func convertToSize() -> CGSize {
        CGSize(width: Int(self.width), height: Int(self.height))
    }
}

public class RootViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    lazy var preview: MTKView = {
        let box = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        box.framebufferOnly = false
        box.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        box.backgroundColor = UIColor.clear
        return box
    }()

    var render: Render!

    var deviceActiveFormatObs: AnyCancellable?
    public let session = AVCaptureSession()

    private let dataOutputQueue = DispatchQueue(label: "com.simplehealth.camera.data.output")

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .red
        view.addSubview(preview)

        preview.translatesAutoresizingMaskIntoConstraints = false;
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        render = Render(view: self.preview)
        preview.delegate = render

        AVCaptureDevice.requestAccess(for: .video) { _ in }

        session.beginConfiguration()
        session.sessionPreset = .high

        let deviceSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back)
        let device = deviceSession.devices.first!

        deviceActiveFormatObs = device.publisher(for: \.activeFormat).sink { format in
            let captureBufferSize = format.formatDescription.dimensions.convertToSize()
            self.render.sampleBufferSize = captureBufferSize
        }

        let input = try! AVCaptureDeviceInput(device: device)
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: dataOutputQueue)

        output.videoSettings = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA))
        ]
        session.addOutput(output)

        let conn = output.connection(with: .video)
        conn?.isEnabled = true
        if #available(iOS 17.0, *) {
            let coord = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            conn?.videoRotationAngle = angle
        } else {
            conn?.videoOrientation = .portrait
        }

        session.commitConfiguration()

        Task.detached {
            await self.session.startRunning()
        }

    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = preview.bounds
        render.maskCornerRadiusInViewBounds = 32.0
        render.maskRectInViewBounds = CGRect(x: b.width / 2 - 150, y: b.height / 2 - 150, width: 200, height: 200)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in
            let angle = output.connection(with: .video)?.videoRotationAngle
            render.sampleBufferAngle = angle ?? 0
            render.sampleBuffer = sampleBuffer
        }
    }

}



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

    var contentMode: ContentMode = .scaleAspectFit {
        didSet { if oldValue != contentMode { updateTransform() }}
    }

    var textureTransform: CGAffineTransform = .identity

    init(view: MTKView) {
        self.device = view.device
        self.drawableScale = view.contentScaleFactor
        self.commandQueue = view.device?.makeCommandQueue()
        super.init()

        view.preferredFramesPerSecond = 120

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

    func updateTransform() {
        guard sampleBufferSize != .zero, drawableSize != .zero else {
            textureTransform = .identity
            return
        }

        var transform = CGAffineTransform.identity

        let sampleBufferSize: CGSize = {
            let rect = CGRect(origin: .zero, size: self.sampleBufferSize)
            let rotatedSize = rect.applying(.identity.rotated(by: self.sampleBufferAngle / 180 * .pi)).size
            return CGSize(width: Int(round(rotatedSize.width)), height: Int(round(rotatedSize.height)))
        }()

        let widthScale = drawableSize.width / sampleBufferSize.width
        let heightScale = drawableSize.height / sampleBufferSize.height

        switch contentMode {
        case .scaleAspectFit:
            // meet the minimun scale requirement.
            let scale = min(widthScale, heightScale)
            transform = transform.scaledBy(x: scale, y: scale)

            // move to center
            if scale < heightScale {
                let delta = (drawableSize.height - sampleBufferSize.height * scale) / 2
                transform = transform.translatedBy(x: 0, y: delta)
            } else {
                let delta = (drawableSize.width - sampleBufferSize.width * scale) / 2
                transform = transform.translatedBy(x: delta, y: -0)
            }

        case .scaleAspectFill:
            // meet the maximum scale requirement.
            let scale = max(widthScale, heightScale)
            transform = transform.scaledBy(x: scale, y: scale)

            // move to center
            if scale > heightScale {
                let delta = (sampleBufferSize.height * scale - drawableSize.height) / 2
                transform = transform.translatedBy(x: 0, y: -delta)
            } else {
                let delta = (sampleBufferSize.width * scale - drawableSize.width) / 2
                transform = transform.translatedBy(x: -delta, y: -0)
            }
        }

        textureTransform = transform
    }

    func updateMask() {
        var maskTexture: (any MTLTexture)? = nil
        defer {
            self.maskTexture = maskTexture
        }

        guard let maskRectInViewBounds, drawableSize != .zero, let device else {
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

        guard let buffer = Self.buildMaskBufferInGraySpace(rect: maskRectInViewBounds, cornerRadis: maskCornerRadiusInViewBounds, scale: drawableScale, size: drawableSize) else {
            return
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: buffer, bytesPerRow: width)

        maskTexture = texture
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

        // 3.  Encode the blur.
        let blurKernel = MPSImageGaussianBlur(device: device, sigma: 20.0)
        blurKernel.edgeMode = .clamp
        blurKernel.encode(commandBuffer: commandBuffer,
                    sourceTexture: inputMTLTexture,
                    destinationTexture: blurTexture)

        var transform = textureTransform.inverted().convertToSIMD()

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
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}


extension Render {
    // using MTLPixelFormat.r8Unorm
    // about 5 ms
    static func buildMaskBufferInGraySpace(rect: CGRect, cornerRadis: CGFloat, scale: CGFloat, size: CGSize) -> [UInt8]? {
        let start = mach_absolute_time()

        let width = Int(size.width)
        let height = Int(size.height)

        var buffer = [UInt8](repeating: 0, count: width * height)

        let scaledRect = rect.applying(.identity.scaledBy(x: scale, y: scale))
        let scaledCornerRadius = cornerRadis * scale

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

        let path = UIBezierPath(roundedRect: scaledRect, cornerRadius: scaledCornerRadius)

        context.addPath(path.cgPath)
        context.setFillColor(gray: 1, alpha: 1) // change gray from 0 - 1
        context.fillPath()

        let end = mach_absolute_time()

        print("[*]:", machTimeToSeconds(end - start))
        return buffer
    }

    // using MTLPixelFormat.r8Unorm
    // about 150 ms
    // TODO: convert this function. use image as input and sample it to drawable size
    static func buildMaskBufferInGraySpace2(rect: CGRect, cornerRadis: CGFloat, scale: CGFloat, size: CGSize) -> [UInt8]? {
        let start = mach_absolute_time()
        let uiImage = UIGraphicsImageRenderer(size: size).image { rendererCtx in
            let ctx = rendererCtx.cgContext

            let scaledRect = rect.applying(.identity.scaledBy(x: scale, y: scale))
            let scaledCornerRadius = cornerRadis * scale

            let path = UIBezierPath(roundedRect: scaledRect, cornerRadius: scaledCornerRadius)
            ctx.addPath(path.cgPath)

            ctx.setFillColor(gray: 1, alpha: 0.5) // change gray from 0 - 1
            ctx.fillPath()
        }
        let end1 = mach_absolute_time()

        print("[*]:", machTimeToSeconds(end1 - start))

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

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(uiImage.cgImage!, in: rect)

        let end2 = mach_absolute_time()

        print("[*]:", machTimeToSeconds(end2 - end1))
        return buffer
    }
}

func machTimeToSeconds(_ machTime: UInt64) -> Double {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo) // Initialize timebaseInfo

    let nanos = Double(machTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
    return nanos / 1e9
}
