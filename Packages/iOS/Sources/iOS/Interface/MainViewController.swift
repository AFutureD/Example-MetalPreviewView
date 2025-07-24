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

//    lazy var avPreview: AVCaptureVideoPreviewLayer = {
//        AVCaptureVideoPreviewLayer()
//    }()

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
    
    var drawableSize: CGSize = .zero {
        didSet { if oldValue != drawableSize { updateTransform() }}
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
        self.commandQueue = view.device?.makeCommandQueue()
        super.init()

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

    func draw(in view: MTKView) {
        guard
            let sampleBuffer = sampleBuffer,
            let drawable = view.currentDrawable,
            let commandQueue = commandQueue,
            let sampleBufferTextureCache = sampleBufferTextureCache,
            let pipelineState = computePipelineState
        else {
            return
        }

        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var inputTexture: CVMetalTexture?

        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sampleBufferTextureCache,
                                                  pixelBuffer, nil, .bgra8Unorm,
                                                  width, height, 0, &inputTexture)

        guard let inputMTLTexture = CVMetalTextureGetTexture(inputTexture!) else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!

        var transform = textureTransform.inverted().convertToSIMD()

        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputMTLTexture, index: 0)
        computeEncoder.setTexture(drawable.texture, index: 1)
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
