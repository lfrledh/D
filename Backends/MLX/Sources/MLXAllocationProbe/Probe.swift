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

@main struct Probe {
    static func main() async throws {
        if CommandLine.arguments.count == 2 {
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
