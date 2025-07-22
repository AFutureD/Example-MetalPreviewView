//
//  PreviewMetalView.swift
//  FaceYoga
//
//  Created by Huanan on 2025/3/18.
//

import AVFoundation
import MetalKit

public extension CGRect {
    init(center: CGPoint, size: CGSize) {
        let origin = CGPoint(x: center.x - size.width / 2.0, y: center.y - size.height / 2.0)
        self.init(origin: origin, size: size)
    }

    var center: CGPoint {
        CGPoint(x: origin.x + width / 2, y: origin.y + height / 2)
    }
}

class PreviewMetalView: MTKView, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum ContentMode {
        case resizeAspectFit
        case resizeAspectFill
    }

    private lazy var commandQueue = self.device?.makeCommandQueue()
    private lazy var context: CIContext = {
        guard let device = self.device else {
            assertionFailure("The PreviewUIView should have a Metal device")
            return CIContext()
        }
        return CIContext(mtlDevice: device)
    }()

    private var imageToDisplay: CIImage? {
        didSet {
            setNeedsDisplay()
        }
    }

    private let dataOutputQueue = DispatchQueue(label: "com.simplehealth.camera.data.output")
    open weak var videoOutput: AVCaptureVideoDataOutput? {
        didSet {
            videoOutput?.setSampleBufferDelegate(self, queue: dataOutputQueue)
        }
    }

    var rectOfInterest: CGRect?

    public private(set) var textureContentMode: ContentMode = .resizeAspectFill
    public private(set) var textureTransform: CGAffineTransform = .identity

    // may not on main
    var sampleBuffer: CMSampleBuffer? {
        didSet {
            self.handle(sampleBuffer: sampleBuffer)
        }
    }
    var sizeOfInterest: CGSize

    private var drawableSizeOfInterest: CGSize {
        .init(width: sizeOfInterest.width * drawableScale, height: sizeOfInterest.height * drawableScale)
    }

    var viewBounds: CGRect = .zero
    var drawableScale: CGFloat = 1.0

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(frame: CGRect,
         device: MTLDevice? = MTLCreateSystemDefaultDevice(),
         sizeOfInterest: CGSize = .zero)
    {
        self.sizeOfInterest = sizeOfInterest
        self.sampleBuffer = nil
        super.init(frame: frame, device: device)

        isPaused = true // draw by setNeedsDisplay method.
        enableSetNeedsDisplay = true
        autoResizeDrawable = true // drawsize follow the view's bounds

        colorPixelFormat = (traitCollection.displayGamut == .P3) ? .bgr10_xr_srgb : .bgra8Unorm_srgb

        framebufferOnly = false // force reinder CIIImage render into view framebuffer
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewBounds = bounds
        drawableScale = drawableSize.width / bounds.width // height should be the same
    }

    // draw image on layer
    override func draw(_: CGRect) {
        guard let currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer()
        else {
            return
        }

        guard let input = imageToDisplay else {
            return
        }

        let destination = CIRenderDestination(width: Int(drawableSize.width),
                                              height: Int(drawableSize.height),
                                              pixelFormat: colorPixelFormat,
                                              commandBuffer: commandBuffer,
                                              mtlTextureProvider: { () -> MTLTexture in
                                                  return currentDrawable.texture
                                              })

        do {
            try context.startTask(toClear: destination)
            let cropRect: CGRect = .init(center: input.extent.center, size: drawableSize) // only render center part
            try context.startTask(toRender: input, from: cropRect, to: destination, at: .zero)
        } catch {
            assertionFailure("Failed to render to preview view: \(error)")
        }

        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }

    func handle(sampleBuffer: CMSampleBuffer?) {
        guard let sampleBuffer, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let inputImage = CIImage(cvPixelBuffer: buffer)
        let imageSize = inputImage.extent.size

        setTextureTransformIfNeeded(width: imageSize.width, height: imageSize.height)
        setRectOfInterest(sizeOfInterest: drawableSizeOfInterest, textureSize: imageSize)

        let transform = textureTransform
        let centeredImage = transformImage(image: inputImage, transform: transform)

        let resultImage = filter(image: centeredImage)

        Task {
            self.imageToDisplay = resultImage
        }
    }

    func filter(image: CIImage) -> CIImage {
        image
    }

    static func calculatorTransform(width: CGFloat, height: CGFloat, drawableSize: CGSize, contentMode: ContentMode) -> CGAffineTransform {
        let internalBounds = drawableSize
        let textureWidth = width
        let textureHeight = height
        var resizeAspect: CGFloat = 1.0

        var scaleX = CGFloat(internalBounds.width / textureWidth)
        var scaleY = CGFloat(internalBounds.height / textureHeight)

        switch contentMode {
        case .resizeAspectFit:
            resizeAspect = min(scaleX, scaleY)
            if scaleX < scaleY {
                scaleY = scaleX / scaleY
                scaleX = 1.0
            } else {
                scaleX = scaleY / scaleX
                scaleY = 1.0
            }
        case .resizeAspectFill:
            resizeAspect = max(scaleX, scaleY)
            if scaleX > scaleY {
                scaleY = scaleX / scaleY
                scaleX = 1.0
            } else {
                scaleX = scaleY / scaleX
                scaleY = 1.0
            }
        }

        // scale
        var transform = CGAffineTransform.identity.scaledBy(x: resizeAspect, y: resizeAspect)
        let textureBounds = CGRect(origin: .zero, size: CGSize(width: textureWidth, height: textureHeight))
        let tranformRect = textureBounds.applying(transform)

        // move
        let xShift = (internalBounds.width - tranformRect.size.width) / 2
        let yShift = (internalBounds.height - tranformRect.size.height) / 2
        transform = transform.translatedBy(x: xShift, y: yShift)
        return transform
    }

    private var previousTextureSize: CGSize = .zero
    func setTextureTransformIfNeeded(width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else {
            textureTransform = .identity
            return
        }
        guard previousTextureSize.width != width || previousTextureSize.height != height else {
            return
        }
        previousTextureSize = .init(width: width, height: height)

        let transform = Self.calculatorTransform(width: width, height: height, drawableSize: drawableSize, contentMode: textureContentMode)
        textureTransform = transform
    }

    func setRectOfInterest(sizeOfInterest: CGSize, textureSize: CGSize) {
        let textureSizeOfInterest = sizeOfInterest.applying(textureTransform.inverted())
        // Notice: do not know why the AVCaptureMetadataOutput's axis is differrent to video's
        let roiUnit: CGSize = .init(width: textureSizeOfInterest.height / textureSize.height, height: textureSizeOfInterest.width / textureSize.width)

        let roi: CGRect = .init(x: 0.5 - roiUnit.width / 2, y: 0.5 - roiUnit.height / 2, width: roiUnit.width, height: roiUnit.height)

        Task {
            self.rectOfInterest = roi
        }
    }

    func transformImage(image: CIImage, transform: CGAffineTransform) -> CIImage {
        guard let filter = CIFilter(name: "CIAffineTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(transform, forKey: kCIInputTransformKey)

        return filter.outputImage ?? image
    }
}
