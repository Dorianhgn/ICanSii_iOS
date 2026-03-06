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
    @Published var fps: Double = 0.0
    @Published var inferenceTimeMs: Double = 0.0
    
    private var vnRequest: VNCoreMLRequest?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var fpsStartTime: CFTimeInterval = 0
    
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
        if let error = error {
            print("Erreur Vision: \(error)")
            return
        }
        
        guard let results = request.results as? [VNCoreMLFeatureValueObservation] else { return }
        
        // On récupère le tenseur de détection [1, 300, 38]
        guard let boxFeature = results.first(where: { $0.featureValue.multiArrayValue?.shape.count == 3 }),
              let boxArray = boxFeature.featureValue.multiArrayValue else { return }
        
        let numDetections = boxArray.shape[1].intValue // 300
        let stride1 = boxArray.strides[1].intValue
        let stride2 = boxArray.strides[2].intValue
        
        // Pointeur Zéro-copie pour des performances maximales
        let pointer = boxArray.dataPointer.assumingMemoryBound(to: Float.self)
        
        var newDetections: [YoloDetection] = []
        let modelInputSize: Float = 640.0 // Résolution interne de YOLO
        
        for i in 0..<numDetections {
            // Index 4 : La confiance
            let conf = pointer[i * stride1 + 4 * stride2]
            
            // On ignore les "cases vides" du tableau (ou les détections faibles)
            if conf < 0.25 { continue }
            
            // Index 5 : L'ID de la classe
            let classId = Int(pointer[i * stride1 + 5 * stride2])
            
            // Index 0 à 3 : Les coordonnées (minX, minY, maxX, maxY)
            let minX = pointer[i * stride1 + 0 * stride2]
            let minY = pointer[i * stride1 + 1 * stride2]
            let maxX = pointer[i * stride1 + 2 * stride2]
            let maxY = pointer[i * stride1 + 3 * stride2]
            
            // Normalisation pour SwiftUI (0.0 à 1.0)
            let normMinX = minX / modelInputSize
            let normMinY = minY / modelInputSize
            let normMaxX = maxX / modelInputSize
            let normMaxY = maxY / modelInputSize
            
            let rect = CGRect(
                x: CGFloat(normMinX),
                y: CGFloat(normMinY),
                width: CGFloat(normMaxX - normMinX),
                height: CGFloat(normMaxY - normMinY)
            )
            
            let detection = YoloDetection(
                label: getClassName(for: classId),
                confidence: conf,
                boundingBox: rect
            )
            newDetections.append(detection)
        }
        
        DispatchQueue.main.async {
            self.detections = newDetections
        }
    }
    
    // Petit dictionnaire pour traduire l'ID de YOLO en texte lisible
    // (J'ai mis les objets qu'on voit sur ta photo de bureau)
    private func getClassName(for id: Int) -> String {
        let cocoClasses = [
            0: "Person", 39: "Bottle", 62: "TV", 63: "Laptop",
            64: "Mouse", 65: "Remote", 66: "Keyboard", 67: "Cell Phone"
        ]
        return cocoClasses[id] ?? "Obj \(id)"
    }
}