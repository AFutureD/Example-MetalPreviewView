//
//  ViewController.swift
//  Pin
//
//  Created by AFuture on 2023/9/12.
//

import Metal
import simd
import Foundation
import AVFoundation
import UIKit
import MetalKit
import Combine


public class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    lazy var preview: MTKView = {
        let box = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        box.preferredFramesPerSecond = 120
        box.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        box.backgroundColor = UIColor.clear
        return box
    }()

    lazy var render: Render = Render(view: self.preview)

    var deviceActiveFormatObs: AnyCancellable?
    public let session = AVCaptureSession()

    private let dataOutputQueue = DispatchQueue(label: "me.afuture.device.camera.data.output")

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
            let angle: CGFloat? = if #available(iOS 17.0, *) {
                output.connection(with: .video)?.videoRotationAngle
            } else {
                90.0
            }
            render.sampleBufferAngle = angle ?? 0
            render.sampleBuffer = sampleBuffer
        }
    }

}
