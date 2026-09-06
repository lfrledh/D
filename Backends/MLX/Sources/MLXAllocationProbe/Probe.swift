import MLX
import MLXLLM
import MLXLMCommon
import Foundation

// Diagnostic experiment only: _updateInternal reproduces the upstream weight-update path.
@inline(never) func exercise(_ mode: Int) {
    let w = MLXRandom.uniform(Float(-1)..<Float(1), [64, 64], key: MLXRandom.key(0))
    guard mode > 0 else { return }
    let q = quantized(w, groupSize: 64, bits: 4)
    guard mode > 1 else { return }
    guard let biases = q.biases else { fatalError("Affine quantization requires biases") }
    if mode == 3 { eval(q.wq, q.scales, biases) }
    q.wq._updateInternal(zeros(q.wq.shape, dtype: q.wq.dtype))
    q.scales._updateInternal(zeros(q.scales.shape, dtype: q.scales.dtype))
    biases._updateInternal(zeros(biases.shape, dtype: biases.dtype))
}

@inline(never) func loadOnly(_ directory: URL) async throws {
    let state = MLXRandom.RandomState(seed: 0)
    try await withRandomState(state) {
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: directory))
        withExtendedLifetime(container) {}
    }
}

// Run in a separate process: deliberately touching the global RNG establishes a
// process-lifetime owner and would contaminate backend tests that require zero active arrays.
@inline(never) func scopedNoise() {
    let state = MLXRandom.RandomState(seed: 42)
    withRandomState(state) {
        eval(MLXRandom.normal([1, 1024, 128]))
    }
}

@inline(never) func globalNoise() {
    MLXRandom.seed(42)
    eval(MLXRandom.normal([1, 1024, 128]))
}

func rngSnapshot(_ phase: String) {
    Stream.gpu.synchronize()
    Stream.cpu.synchronize()
    Memory.clearCache()
    print("D_RNG_CONTROL phase=\(phase) activeBytes=\(Memory.activeMemory) cacheBytes=\(Memory.cacheMemory)")
}

@main struct Probe {
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--rng-ownership-control"] {
            rngSnapshot("baseline")
            scopedNoise()
            rngSnapshot("scoped_noise_released")
            globalNoise()
            rngSnapshot("global_noise_retained")
            MLXRandom.seed(0)
            rngSnapshot("global_state_reseeded")
        } else if CommandLine.arguments.count == 2 {
            for iteration in 1...5 {
                try await loadOnly(URL(fileURLWithPath: CommandLine.arguments[1]))
                Stream.gpu.synchronize()
                Stream.cpu.synchronize()
                Memory.clearCache()
                print("loadOnly iteration=\(iteration) activeBytes=\(Memory.activeMemory)")
            }
        } else {
            for mode in 0...3 {
                for iteration in 1...10 {
                    exercise(mode)
                    Stream.gpu.synchronize()
                    Stream.cpu.synchronize()
                    Memory.clearCache()
                    print("mode=\(mode) iteration=\(iteration) activeBytes=\(Memory.activeMemory)")
                }
            }
        }
    }
}
