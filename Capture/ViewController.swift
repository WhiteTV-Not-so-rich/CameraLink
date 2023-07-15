//
//  ViewController.swift
//  Capture
//
//  Created by George on 6/8/23.
//

import UIKit
import Photos
import AVFoundation

extension UIImage {
    func rotate(radians: CGFloat) -> UIImage? {
        let rotatedSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size
        UIGraphicsBeginImageContext(rotatedSize)
        if let context = UIGraphicsGetCurrentContext() {
            let origin = CGPoint(x: rotatedSize.width / 2.0,
                                 y: rotatedSize.height / 2.0)
            context.translateBy(x: origin.x, y: origin.y)
            context.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2.0,
                            y: -size.height / 2.0,
                            width: size.width,
                            height: size.height))
            let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return rotatedImage
        }
        return nil
    }
}

private enum SessionSetupResult {
    case success
    case notAuthorized
    case configurationFailed
}

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let audioEngine = AVAudioEngine()
    @IBOutlet weak var previewView: PreviewView!
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue")
    private var setupResult: SessionSetupResult = .success
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    @objc dynamic var audioDeviceInput: AVCaptureDeviceInput!
    private var isSessionRunning = false
    private var isRecording = false
    private var movieOutputURL: URL?
    private var recordButton: UIBarButtonItem!
    private var movieOutput: AVCaptureMovieFileOutput?
    let captureAudioOutput = AVCaptureAudioDataOutput()
    var windowOrientation: UIInterfaceOrientation {
        return view.window?.windowScene?.interfaceOrientation ?? .unknown
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        audioEngine.connect(audioEngine.inputNode, to: audioEngine.outputNode, format: audioEngine.inputNode.inputFormat(forBus: 0))
        try! audioEngine.start()
        
        configureNavigationBar()
        
        photoOutput.setPreparedPhotoSettingsArray([AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])], completionHandler: nil)

        
        
        // Set up the video preview view.
        previewView.session = session
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
            
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
        }
        sessionQueue.async {
            self.configureSession()
        }
    }
    
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        session.usesApplicationAudioSession = true
        // Add video input.
        do {
            let deviceSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            
            guard let videoDevice = deviceSession.devices.first else {
                print("Default video device is unavailable.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
            
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                
                DispatchQueue.main.async {
                    var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
                    if self.windowOrientation != .unknown {
                        if let videoOrientation = AVCaptureVideoOrientation(rawValue: self.windowOrientation.rawValue) {
                            initialVideoOrientation = videoOrientation
                        }
                    }
                    
                    self.previewView.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
                }
            } else {
                print("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Add an audio input device.
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
            print("Audio Device: \(audioDevice?.localizedName)")
            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                print("Could not add audio device input to the session")
            }
        } catch {
            print("Could not create audio device input: \(error)")
        }
        session.automaticallyConfiguresApplicationAudioSession = false
        
        // Add the photo output.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else {
            print("Could not add photo output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Set the audio session category and mode.
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            print("Failed to set the audio session configuration")
        }
        session.commitConfiguration()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        sessionQueue.async {
            switch self.setupResult {
            case .success:
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                do {
                    // 设置音频会话
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP, .defaultToSpeaker])
                    try audioSession.setActive(true)
                } catch {
                    print("Failed to configure audio session: \(error)")
                }
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "AVCam doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                  options: [:],
                                                  completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    self.stopAudioEngine()
                    let alertMsg = "捕获会话配置期间出现问题时的警报消息"
                    let message = NSLocalizedString("请尝试重新拔插采集卡并确保该采集卡受支持，点击“好的”以退出应用。", comment: alertMsg)
                    let alertController = UIAlertController(title: "检测不到外置设备！", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("好的", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: { _ in
                        exit(0);
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }
    
    @objc private func refreshButtonTapped() {
        let alertController = UIAlertController(title: "已刷新视频流。",
                                                message: nil, preferredStyle: .alert)
        // Show the alert
        self.present(alertController, animated: true, completion: nil)
        // Dismiss after two seconds
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
            self.presentedViewController?.dismiss(animated: false, completion: nil)
        }
        // 停止会话
        sessionQueue.async {
            if self.isSessionRunning {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            }
            
            // 重新设置视频预览图层的连接
            DispatchQueue.main.async {
                var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
                if self.windowOrientation != .unknown {
                    if let videoOrientation = AVCaptureVideoOrientation(rawValue: self.windowOrientation.rawValue) {
                        initialVideoOrientation = videoOrientation
                    }
                }
                self.previewView.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
            }
            
            // 开始会话
            self.sessionQueue.async {
                if !self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                }
            }
        }
    }
    
    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.reset()
    }
    
    // Top navigation bar configuration
    private func configureNavigationBar() {
        // Create a navigation bar with a title
        let navigationBar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: view.frame.size.width, height: 44))
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        navigationBar.isTranslucent = false
        navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationBar.shadowImage = UIImage()
        
        // Create a navigation item with a title
        let navigationItem = UINavigationItem(title: "CameraLink")
        
        // Create the refresh button
        let refreshButton = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshButtonTapped))
        navigationItem.leftBarButtonItem = refreshButton
        
        // Create the record button
        let recordButton = UIBarButtonItem(image: UIImage(systemName: "record.circle"), style: .plain, target: self, action: #selector(recordButtonTapped))
        navigationItem.leftBarButtonItem = recordButton
        
        // Create the photo button
        let photoButton = UIBarButtonItem(image: UIImage(systemName: "camera"), style: .plain, target: self, action: #selector(photoButtonTapped))
        navigationItem.leftBarButtonItems = [recordButton, photoButton, refreshButton]
        
        // Add the navigation item to the navigation bar
        navigationBar.items = [navigationItem]
        
        // Add the navigation bar to the view
        view.addSubview(navigationBar)
        
        // Add constraints for the navigation bar
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    @objc private func recordButtonTapped() {
        let alertController = UIAlertController(title: "录制功能开发中...",
                                                message: nil, preferredStyle: .alert)
        // Show the alert
        self.present(alertController, animated: true, completion: nil)
        // Dismiss after two seconds
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2) {
            self.presentedViewController?.dismiss(animated: false, completion: nil)
        }
    }
    
    
    @objc private func photoButtonTapped() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            print("Error capturing photo: \(error!)")
            return
        }
        
        guard let imageData = photo.fileDataRepresentation() else {
            print("Unable to get photo file data")
            return
        }
        
        let image = UIImage(data: imageData)
        
        // Rotate the image to match the video preview layer's orientation
        let rotatedImage = image?.rotate(radians: .pi / 2) // Rotate 90 degrees clockwise
        
        // Save the rotated image to the Photos library
        if let rotatedImageData = rotatedImage?.jpegData(compressionQuality: 1.0) {
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: rotatedImageData, options: nil)
            }, completionHandler: { success, error in
                if success {
                    print("Photo saved to library")
                } else {
                    print("Error saving photo: \(error!)")
                }
            })
        }
    }
}
