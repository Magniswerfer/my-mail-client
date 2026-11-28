#if canImport(Accelerate)
import Accelerate
#endif

/// The few vector operations the classifier and semantic search need. Accelerate (vDSP) on
/// Apple platforms; plain loops elsewhere (Linux server, ADR 0007), where vectors are rare
/// because there's no on-device embedder.
enum VectorMath {
    /// Σ a[i]·b[i] over the first `count` elements.
    static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
        return result
        #else
        var result: Float = 0
        for i in 0..<count { result += a[i] * b[i] }
        return result
        #endif
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        // An empty buffer may have no base address.
        guard count > 0 else { return 0 }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in dot(pa.baseAddress!, pb.baseAddress!, count: count) }
        }
    }

    /// v[i] *= factor, in place.
    static func scale(_ v: UnsafeMutablePointer<Float>, by factor: Float, count: Int) {
        #if canImport(Accelerate)
        var f = factor
        vDSP_vsmul(v, 1, &f, v, 1, vDSP_Length(count))
        #else
        for i in 0..<count { v[i] *= factor }
        #endif
    }

    /// y[i] += a · x[i], in place.
    static func addScaled(_ x: UnsafePointer<Float>, times a: Float, to y: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var f = a
        vDSP_vsma(x, 1, &f, y, 1, y, 1, vDSP_Length(count))
        #else
        for i in 0..<count { y[i] += a * x[i] }
        #endif
    }

    static func sumOfSquares(_ v: [Float]) -> Float {
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_svesq(v, 1, &result, vDSP_Length(v.count))
        return result
        #else
        return v.reduce(0) { $0 + $1 * $1 }
        #endif
    }

    /// Mean and (population) standard deviation, as `vDSP_normalize` reports them.
    static func meanAndDeviation(_ v: [Float]) -> (mean: Float, deviation: Float) {
        guard !v.isEmpty else { return (0, 0) }
        #if canImport(Accelerate)
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(v, 1, nil, 1, &mean, &std, vDSP_Length(v.count))
        return (mean, std)
        #else
        let mean = v.reduce(0, +) / Float(v.count)
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(v.count)
        return (mean, variance.squareRoot())
        #endif
    }

    /// L2-normalised copy (unchanged when the norm is 0).
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sumOfSquares(v).squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
