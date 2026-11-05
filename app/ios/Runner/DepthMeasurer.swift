import ARKit
import Flutter
import UIKit

/// Abordagem B no iOS: LiDAR (iPhone/iPad Pro) via ARKit sceneDepth.
/// Mesmo algoritmo do DepthMeasurer.kt: plano robusto no anel dos blocos,
/// mediana do disco central, várias leituras e dispersão (IQR).
final class DepthMeasurer {
    struct Result { let depthMm, spreadMm, distanceMm: Float; let frames: Int }
    enum Failure: Error { case tooFar(Float), lowConfidence }

    static let innerRadiusMm: Float = 2, ringInMm: Float = 7, ringOutMm: Float = 14
    static let maxMmPerPx: Float = 2.5, planeTolMm: Float = 2.5

    let framesNeeded: Int
    private var estimates: [Float] = [], distances: [Float] = []
    private var lowConf = 0
    init(framesNeeded: Int = 20) { self.framesNeeded = framesNeeded }
    func reset() { estimates.removeAll(); distances.removeAll(); lowConf = 0 }

    /// `viewPoint` normalizado (0..1) na view; `viewport`/`orientation` da ARSCNView.
    func accumulate(frame: ARFrame, viewPoint: CGPoint, viewport: CGSize,
                    orientation: UIInterfaceOrientation) throws -> Result? {
        // smoothedSceneDepth = média temporal do próprio ARKit (menos ruído)
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let conf = depth.confidenceMap else { return nil }
        let dm = depth.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly); CVPixelBufferLockBaseAddress(conf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly); CVPixelBufferUnlockBaseAddress(conf, .readOnly) }

        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)       // ~256x192
        let dRow = CVPixelBufferGetBytesPerRow(dm) / MemoryLayout<Float32>.size
        let cRow = CVPixelBufferGetBytesPerRow(conf)
        let dPtr = CVPixelBufferGetBaseAddress(dm)!.assumingMemoryBound(to: Float32.self)
        let cPtr = CVPixelBufferGetBaseAddress(conf)!.assumingMemoryBound(to: UInt8.self)

        // 1) toque -> coordenada normalizada da imagem (inverso do displayTransform)
        let t = frame.displayTransform(for: orientation, viewportSize: viewport).inverted()
        let p = viewPoint.applying(t)
        let cu = Float(p.x) * Float(w), cv = Float(p.y) * Float(h)
        guard cu >= 0, cv >= 0, cu < Float(w), cv < Float(h) else { return nil }

        // intrínsecos são da capturedImage: escala para o depthMap
        let K = frame.camera.intrinsics, res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, px = K[2][0] * sx, py = K[2][1] * sy

        func z(_ u: Int, _ v: Int) -> Float { dPtr[v * dRow + u] * 1000 }       // m -> mm
        func c(_ u: Int, _ v: Int) -> UInt8 { cPtr[v * cRow + u] }

        let zc = z(Int(cu), Int(cv))
        guard zc > 0 else { return nil }
        let mmPerPx = zc / fx
        if mmPerPx > Self.maxMmPerPx { throw Failure.tooFar(zc) }

        // 2) anel (blocos) e disco (fundo) em 3D, só confiança alta
        let rOut = Int((Self.ringOutMm / mmPerPx).rounded())
        var ring: [SIMD3<Float>] = [], core: [SIMD3<Float>] = []
        var total = 0, rejected = 0
        for v in max(0, Int(cv) - rOut)...min(h - 1, Int(cv) + rOut) {
            for u in max(0, Int(cu) - rOut)...min(w - 1, Int(cu) + rOut) {
                let du = Float(u) - cu, dv = Float(v) - cv
                let r = (du * du + dv * dv).squareRoot() * mmPerPx
                let isCore = r <= Self.innerRadiusMm
                let isRing = r >= Self.ringInMm && r <= Self.ringOutMm
                guard isCore || isRing else { continue }
                total += 1
                let zz = z(u, v)
                guard zz > 0, c(u, v) == UInt8(ARConfidenceLevel.high.rawValue) else { rejected += 1; continue }
                let pt = SIMD3<Float>((Float(u) - px) * zz / fx, (Float(v) - py) * zz / fy, zz)
                if isCore { core.append(pt) } else { ring.append(pt) }
            }
        }
        if ring.count < 12 || core.isEmpty {
            if total > 0, rejected > total / 2 { lowConf += 1 }
            if lowConf > framesNeeded { throw Failure.lowConfidence }
            return nil
        }

        // 3) plano robusto do topo dos blocos
        guard var plane = Self.fitPlane(ring) else { return nil }
        for _ in 0..<4 {
            let keep = ring.filter { $0.z - (plane.x * $0.x + plane.y * $0.y + plane.z) < Self.planeTolMm }
            if keep.count >= 12, let p2 = Self.fitPlane(keep) { plane = p2 }
        }
        let norm = (plane.x * plane.x + plane.y * plane.y + 1).squareRoot()

        // 4) profundidade do quadro
        let prof = core.map { ($0.z - (plane.x * $0.x + plane.y * $0.y + plane.z)) / norm }.sorted()
        estimates.append(prof[prof.count / 2]); distances.append(zc)

        guard estimates.count >= framesNeeded else { return nil }
        let s = estimates.sorted()
        let result = Result(depthMm: max(0, s[s.count / 2]),
                            spreadMm: abs(s[(s.count * 3) / 4] - s[s.count / 4]),
                            distanceMm: distances.sorted()[distances.count / 2],
                            frames: s.count)
        reset()
        return result
    }

    /// z = a x + b y + c por mínimos quadrados (retorna (a, b, c)).
    static func fitPlane(_ pts: [SIMD3<Float>]) -> SIMD3<Float>? {
        var A = simd_double3x3(), B = SIMD3<Double>()
        for p in pts {
            let r = SIMD3<Double>(Double(p.x), Double(p.y), 1)
            A += simd_double3x3(rows: [r * r.x, r * r.y, r * r.z])
            B += r * Double(p.z)
        }
        guard abs(A.determinant) > 1e-9 else { return nil }
        let x = A.inverse * B
        return SIMD3<Float>(Float(x.x), Float(x.y), Float(x.z))
    }
}

// MARK: - Platform view

final class ARDepthView: NSObject, FlutterPlatformView, ARSessionDelegate {
    static weak var active: ARDepthView?

    private let sceneView = ARSCNView()
    private let measurer = DepthMeasurer(framesNeeded: 20)
    private var pending: (CGPoint, FlutterResult)?

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = false
        let cfg = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            cfg.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            cfg.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(cfg)
        ARDepthView.active = self
    }

    deinit { sceneView.session.pause() }

    func view() -> UIView { sceneView }

    func measure(at p: CGPoint, result: @escaping FlutterResult) {
        measurer.reset()
        pending = (p, result)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let (p, result) = pending else { return }
        let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        do {
            guard let r = try measurer.accumulate(frame: frame, viewPoint: p,
                                                  viewport: sceneView.bounds.size,
                                                  orientation: orientation) else { return }
            pending = nil
            result(["depthMm": r.depthMm, "spreadMm": r.spreadMm,
                    "distanceMm": r.distanceMm, "frames": r.frames])
        } catch DepthMeasurer.Failure.tooFar(let z) {
            pending = nil
            result(FlutterError(code: "TOO_FAR", message: "Aproxime o celular (\(Int(z)) mm)", details: nil))
        } catch {
            pending = nil
            result(FlutterError(code: "LOW_CONFIDENCE", message: "Sensor com baixa confiança", details: nil))
        }
    }
}

final class ARDepthViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        ARDepthView()
    }
}
