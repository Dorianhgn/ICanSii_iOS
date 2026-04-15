import Foundation
import CoreML
import Vision
import Combine
import CoreGraphics
import QuartzCore

// Structure pour stocker nos résultats
struct YoloDetection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect // Coordonnées normalisées (0.0 à 1.0)
    let classId: Int
    let maskCoefficients: [Float] // Les 32 valeurs du masque
}

struct VisionFrameOutput {
    let detections: [YoloDetection]
    let prototypes: MLMultiArray
    let spatialFrame: SpatialFrame
}

enum YoloModelType: String, CaseIterable, Identifiable {
    case none = "None"
    case nano = "YOLO26n-seg"
    case small = "YOLO26s-seg"
    
    var id: String { self.rawValue }
    
    // Le nom exact du fichier sans l'extension
    var filename: String? {
        switch self {
        case .none: return nil
        case .nano: return "yolo26n-seg"
        case .small: return "yolo26s-seg"
        }
    }
}

final class VisionManager: ObservableObject {
    @Published var activeModel: YoloModelType = .none {
        didSet { setupModel() }
    }
    
    @Published var detections: [YoloDetection] = []
    @Published var currentPrototypes: MLMultiArray?
    @Published var latestFrameOutput: VisionFrameOutput?
    @Published var fps: Double = 0.0
    @Published var inferenceTimeMs: Double = 0.0
    
    private var vnRequest: VNCoreMLRequest?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var fpsStartTime: CFTimeInterval = 0

    private let pendingFrameLock = NSLock()
    private var pendingFrame: SpatialFrame?
    
    init() {
        setupModel()
    }
    
    private func setupModel() {
        guard let filename = activeModel.filename else {
            self.vnRequest = nil
            DispatchQueue.main.async {
                self.detections = []
                self.fps = 0
                self.inferenceTimeMs = 0
            }
            return
        }
        
        // Xcode compile les .mlpackage en .mlmodelc dans l'application finale
        guard let modelURL = Bundle.main.url(forResource: filename, withExtension: "mlmodelc") else {
            print("Erreur: Modèle \(filename) introuvable dans le bundle.")
            return
        }
        
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // Utilise le Neural Engine (ANE) + GPU
            
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)
            
            let request = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
                self?.processResults(for: request, error: error)
            }
            
            // YOLO s'attend généralement à des images carrées (ex: 640x640), Vision s'occupe du redimensionnement
            request.imageCropAndScaleOption = .scaleFill
            self.vnRequest = request
            
        } catch {
            print("Erreur lors de l'initialisation du modèle: \(error)")
        }
    }
    
    // Fonction appelée par le ARManager (sur un thread de background)
    func process(frame: SpatialFrame) {
        guard let request = vnRequest else { return }

        pendingFrameLock.lock()
        pendingFrame = frame
        pendingFrameLock.unlock()
        
        let startTime = CACurrentMediaTime()
        
        // Calcul des FPS
        if fpsStartTime == 0 { fpsStartTime = startTime }
        frameCount += 1
        let elapsedFPS = startTime - fpsStartTime
        if elapsedFPS >= 1.0 {
            let currentFPS = Double(frameCount) / elapsedFPS
            DispatchQueue.main.async { self.fps = currentFPS }
            frameCount = 0
            fpsStartTime = startTime
        }
        
        // Exécution de l'inférence
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right, options: [:])
        
        do {
            try handler.perform([request])
            
            let endTime = CACurrentMediaTime()
            let inferenceTime = (endTime - startTime) * 1000.0 // en millisecondes
            
            DispatchQueue.main.async {
                self.inferenceTimeMs = inferenceTime
            }
        } catch {
            print("Erreur d'inférence Vision: \(error)")
        }
    }
    
    private func processResults(for request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNCoreMLFeatureValueObservation] else { return }

        pendingFrameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        pendingFrameLock.unlock()

        guard let frame else { return }
        
        // Récupère les boîtes (Tenseur 3D) et les Prototypes (Tenseur 4D)
        guard let boxFeature = results.first(where: { $0.featureValue.multiArrayValue?.shape.count == 3 }),
              let boxArray = boxFeature.featureValue.multiArrayValue,
              let protoFeature = results.first(where: { $0.featureValue.multiArrayValue?.shape.count == 4 }),
              let protoArray = protoFeature.featureValue.multiArrayValue else { return }
        
        let numDetections = boxArray.shape[1].intValue // 300
        let stride1 = boxArray.strides[1].intValue
        let stride2 = boxArray.strides[2].intValue
        let pointer = boxArray.dataPointer.assumingMemoryBound(to: Float.self)
        
        var newDetections: [YoloDetection] = []
        let modelInputSize: Float = 640.0
        
        for i in 0..<numDetections {
            let conf = pointer[i * stride1 + 4 * stride2]
            if conf < 0.25 { continue }
            
            let classId = Int(pointer[i * stride1 + 5 * stride2])
            
            // Extraction des 32 coefficients du masque (Index 6 à 37)
            var coeffs: [Float] = []
            for c in 0..<32 {
                coeffs.append(pointer[i * stride1 + (6 + c) * stride2])
            }
            
            let minX = pointer[i * stride1 + 0 * stride2]
            let minY = pointer[i * stride1 + 1 * stride2]
            let maxX = pointer[i * stride1 + 2 * stride2]
            let maxY = pointer[i * stride1 + 3 * stride2]
            
            let rect = CGRect(
                x: CGFloat(minX / modelInputSize),
                y: CGFloat(minY / modelInputSize),
                width: CGFloat((maxX - minX) / modelInputSize),
                height: CGFloat((maxY - minY) / modelInputSize)
            )
            
            let detection = YoloDetection(
                label: getClassName(for: classId),
                confidence: conf,
                boundingBox: rect,
                classId: classId,
                maskCoefficients: coeffs
            )
            newDetections.append(detection)
        }
        
        DispatchQueue.main.async {
            self.currentPrototypes = protoArray
            self.detections = newDetections
            self.latestFrameOutput = VisionFrameOutput(
                detections: newDetections,
                prototypes: protoArray,
                spatialFrame: frame
            )
        }
    }
    
    // Petit dictionnaire pour traduire l'ID de YOLO en texte lisible
    private func getClassName(for id: Int) -> String {
        let cocoClasses = [
            0: "person",
            1: "bicycle",
            2: "car",
            3: "motorcycle",
            4: "airplane",
            5: "bus",
            6: "train",
            7: "truck",
            8: "boat",
            9: "traffic light",
            10: "fire hydrant",
            11: "stop sign",
            12: "parking meter",
            13: "bench",
            14: "bird",
            15: "cat",
            16: "dog",
            17: "horse",
            18: "sheep",
            19: "cow",
            20: "elephant",
            21: "bear",
            22: "zebra",
            23: "giraffe",
            24: "backpack",
            25: "umbrella",
            26: "handbag",
            27: "tie",
            28: "suitcase",
            29: "frisbee",
            30: "skis",
            31: "snowboard",
            32: "sports ball",
            33: "kite",
            34: "baseball bat",
            35: "baseball glove",
            36: "skateboard",
            37: "surfboard",
            38: "tennis racket",
            39: "bottle",
            40: "wine glass",
            41: "cup",
            42: "fork",
            43: "knife",
            44: "spoon",
            45: "bowl",
            46: "banana",
            47: "apple",
            48: "sandwich",
            49: "orange",
            50: "brocolli",
            51: "carrot",
            52: "hot dog",
            53: "pizza",
            54: "donut",
            55: "cake",
            56: "chair",
            57: "couch",
            58: "potted plant",
            59: "bed",
            60: "dining table",
            61: "toilet",
            62: "tv",
            63: "laptop",
            64: "mouse",
            65: "remote",
            66: "keyboard",
            67: "cell phone",
            68: "microwave",
            69: "oven",
            70: "toaster",
            71: "sink",
            72: "refrigerator",
            73: "book",
            74: "clock",
            75: "vase",
            76: "scissors",
            77: "teddy bear",
            78: "hair drier",
            79: "toothbrush"
        ]
        return cocoClasses[id] ?? "Obj \(id)"
    }
}