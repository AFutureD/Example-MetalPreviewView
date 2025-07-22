//
//  ViewController.swift
//  Pin
//
//  Created by AFuture on 2023/9/12.
//

import UIKit
import AVFoundation

public class RootViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    lazy var preview: PreviewMetalView = {
        let box = PreviewMetalView(frame: .zero)
        return box
    }()

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

//        view.layer.addSublayer(avPreview)
//        avPreview.frame = view.bounds
//        avPreview.session = session

        AVCaptureDevice.requestAccess(for: .video) { _ in }

        session.beginConfiguration()
            session.sessionPreset = .medium

            let deviceSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back)
            let device = deviceSession.devices.first!

            let input = try! AVCaptureDeviceInput(device: device)
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: dataOutputQueue)
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
            preview.sampleBuffer = sampleBuffer

//            view.viewWithTag(1111)?.removeFromSuperview()
//
//            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
//            let ciimage = CIImage(cvPixelBuffer: imageBuffer)
//            let image = UIImage(ciImage: ciimage)
//            let imageView = UIImageView(image: image)
//            imageView.tag = 1111
//
//            view.addSubview(imageView)
//            imageView.frame = .init(x: 150, y: 600, width: 200, height: 200)
//            imageView.contentMode = .scaleAspectFit
        }
    }

}
