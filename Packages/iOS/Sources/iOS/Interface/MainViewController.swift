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

public class RootViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    lazy var preview: MTKView = {
        let box = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        box.framebufferOnly = false
        return box
    }()

    var render: Render!

//    lazy var avPreview: AVCaptureVideoPreviewLayer = {
//        AVCaptureVideoPreviewLayer()
//    }()


    public let session = AVCaptureSession()

    private let dataOutputQueue = DispatchQueue(label: "com.simplehealth.camera.data.output")

    public override func viewDidLoad() {
        super.viewDidLoad()

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

            let input = try! AVCaptureDeviceInput(device: device)
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: dataOutputQueue)
            print(output.availableVideoPixelFormatTypes)
            output.videoSettings = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA))
            ]
            session.addOutput(output)

            let conn = output.connection(with: .video)
            conn?.isEnabled = true
            conn?.videoOrientation = .portrait

        session.commitConfiguration()

        Task.detached {
            await self.session.startRunning()
        }

    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in
            render.sampleBuffer = sampleBuffer
        }
    }

}



class Render: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    var textureCache: CVMetalTextureCache?
    var computePipelineState: MTLComputePipelineState?
    var sampleBuffer: CMSampleBuffer?
    var currentDrawable: CAMetalDrawable?
    lazy var ciContext = CIContext(mtlDevice: device!)

    init(view: MTKView) {
        self.device = view.device
        self.queue = view.device?.makeCommandQueue()
        super.init()

//        view.colorPixelFormat = (view.traitCollection.displayGamut == .P3) ? .bgr10_xr_srgb : .bgra8Unorm_srgb
//        view.colorPixelFormat = .bgr10_xr_srgb

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device!, nil, &textureCache)
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
        
    }

    func draw(in view: MTKView) {
        guard let sampleBuffer = sampleBuffer,
              let drawable = view.currentDrawable,
              let device = device,
              let commandQueue = queue,
              let textureCache = textureCache,
              let pipelineState = computePipelineState else { return }
        
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var inputTexture: CVMetalTexture?

        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache,
                                                  pixelBuffer, nil, .bgra8Unorm,
                                                  width, height, 0, &inputTexture)

        guard let inputMTLTexture = CVMetalTextureGetTexture(inputTexture!) else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputMTLTexture, index: 0)
        computeEncoder.setTexture(drawable.texture, index: 1)

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
