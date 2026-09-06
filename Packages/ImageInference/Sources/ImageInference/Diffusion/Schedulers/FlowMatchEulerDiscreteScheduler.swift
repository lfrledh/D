// File: Packages/ImageInference/Sources/ImageInference/Diffusion/Schedulers/FlowMatchEulerDiscreteScheduler.swift

import Foundation
import MLX
import Core

/// 配置结构体，对应 Python 的 FlowMatchEulerDiscreteScheduler 初始化参数
public struct FlowMatchEulerDiscreteSchedulerConfig: Sendable {
    public var numTrainTimesteps: Int = 1000
    public var shift: Float = 1.0
    public var useDynamicShifting: Bool = false
    public var baseShift: Float? = 0.5
    public var maxShift: Float? = 1.15
    public var baseImageSeqLen: Int = 256
    public var maxImageSeqLen: Int = 4096
    public var invertSigmas: Bool = false
    public var shiftTerminal: Float? = nil
    public var useKarrasSigmas: Bool = false
    public var useExponentialSigmas: Bool = false
    public var useBetaSigmas: Bool = false
    public var timeShiftType: String = "exponential" // "exponential" 或 "linear"
    public var stochasticSampling: Bool = false

    public init() {}
}

/// Flow Matching Euler 离散调度器，用于 SD3 等模型的去噪过程。
/// 参考 diffusers 的 FlowMatchEulerDiscreteScheduler。
public class FlowMatchEulerDiscreteScheduler {
    public let config: FlowMatchEulerDiscreteSchedulerConfig
    public private(set) var timesteps: [Float] = []
    public private(set) var sigmas: [Float] = []
    public private(set) var numInferenceSteps: Int = 0
    private var stepIndex: Int? = nil
    private var beginIndex: Int? = nil

    public init(config: FlowMatchEulerDiscreteSchedulerConfig = FlowMatchEulerDiscreteSchedulerConfig()) {
        self.config = config
    }

    // MARK: - Public Methods

    /// 设置当前调度器的起始索引（用于 img2img 等场景）
    public func setBeginIndex(_ index: Int) {
        self.beginIndex = index
    }

    /// 生成去噪时间步序列。必须在推理前调用。
    /// - Parameters:
    ///   - numInferenceSteps: 推理步数
    ///   - mu: 当 useDynamicShifting 为 true 时需要传入 mu 值（根据图像分辨率计算）
    ///   - sigmas: 可选的自定义 sigma 值
    ///   - timesteps: 可选的自定义 timesteps 值
    public func setTimesteps(
        numInferenceSteps: Int? = nil,
        mu: Float? = nil,
        sigmas: [Float]? = nil,
        timesteps: [Float]? = nil
    ) {
        // 1. 参数校验
        if let sigmas = sigmas, let timesteps = timesteps {
            precondition(sigmas.count == timesteps.count, "sigmas and timesteps must have same length")
        }
        if let numSteps = numInferenceSteps {
            if let sigmas = sigmas {
                precondition(sigmas.count == numSteps, "sigmas count must equal numInferenceSteps")
            }
            if let timesteps = timesteps {
                precondition(timesteps.count == numSteps, "timesteps count must equal numInferenceSteps")
            }
        }

        // 确定推理步数
        let steps: Int
        if let numSteps = numInferenceSteps {
            steps = numSteps
        } else if let sigmas = sigmas {
            steps = sigmas.count
        } else if let timesteps = timesteps {
            steps = timesteps.count
        } else {
            fatalError("Either numInferenceSteps, sigmas, or timesteps must be provided")
        }
        self.numInferenceSteps = steps

        // 2. 准备默认 sigmas
        let sigmaMax: Float = 1.0
        let sigmaMin: Float = 0.0

        var computedSigmas: [Float]
        var computedTimesteps: [Float]

        if let customSigmas = sigmas {
            computedSigmas = customSigmas
            if let customTimesteps = timesteps {
                computedTimesteps = customTimesteps
            } else {
                computedTimesteps = computedSigmas.map { $0 * Float(config.numTrainTimesteps) }
            }
        } else if let customTimesteps = timesteps {
            computedTimesteps = customTimesteps
            computedSigmas = computedTimesteps.map { Float($0) / Float(config.numTrainTimesteps) }
        } else {
            // 默认线性生成 timesteps
            let start = Float(config.numTrainTimesteps)
            let end: Float = 0.0
            let step = (start - end) / Float(steps)
            computedTimesteps = stride(from: start, to: end, by: -step).map { $0 }
            if computedTimesteps.count < steps {
                computedTimesteps.append(end)
            }
            computedSigmas = computedTimesteps.map { $0 / Float(config.numTrainTimesteps) }
        }

        // 3. 动态时间移位 (use_dynamic_shifting)
        if config.useDynamicShifting {
            guard let mu = mu else {
                fatalError("mu must be provided when useDynamicShifting is true")
            }
            computedSigmas = timeShift(mu: mu, sigma: 1.0, t: computedSigmas)
        } else {
            // 静态移位: sigmas = shift * sigmas / (1 + (shift - 1) * sigmas)
            let s = config.shift
            computedSigmas = computedSigmas.map { s * $0 / (1.0 + (s - 1.0) * $0) }
        }

        // 4. 如果需要，拉伸到 shiftTerminal
        if let terminal = config.shiftTerminal {
            computedSigmas = stretchShiftToTerminal(t: computedSigmas, terminal: terminal)
        }

        // 5. 可选的 sigma 转换（Karras, exponential, beta）
        if config.useKarrasSigmas {
            computedSigmas = convertToKarras(sigmas: computedSigmas, numSteps: steps)
        } else if config.useExponentialSigmas {
            computedSigmas = convertToExponential(sigmas: computedSigmas, numSteps: steps)
        } else if config.useBetaSigmas {
            computedSigmas = convertToBeta(sigmas: computedSigmas, numSteps: steps)
        }

        // 6. 根据 invertSigmas 决定是否反转
        if config.invertSigmas {
            computedSigmas = computedSigmas.map { 1.0 - $0 }
            computedTimesteps = computedSigmas.map { $0 * Float(config.numTrainTimesteps) }
            computedSigmas.append(1.0)
        } else {
            computedSigmas.append(0.0)
        }

        self.sigmas = computedSigmas
        self.timesteps = computedTimesteps
        self.stepIndex = nil
        self.beginIndex = nil
    }

    /// 执行一步去噪
    /// - Parameters:
    ///   - modelOutput: 模型预测的输出（与 latents 形状相同）
    ///   - timestep: 当前时间步
    ///   - sample: 当前样本 (latents)
    /// - Returns: 去噪后的新样本
    public func step(
        modelOutput: MLXArray,
        timestep: Float,
        sample: MLXArray
    ) -> MLXArray {
        // 初始化 stepIndex（如果是第一次调用）
        if stepIndex == nil {
            _initStepIndex(timestep: timestep)
        }

        guard let idx = stepIndex, idx < sigmas.count - 1 else {
            fatalError("Invalid step index")
        }

        let sigma = sigmas[idx]
        let sigmaNext = sigmas[idx + 1]

        // 计算 dt = sigma_next - sigma
        let dt = sigmaNext - sigma

        // 转换为 MLXArray 以进行运算
        let sigmaArr = MLXArray(sigma)
        let dtArr = MLXArray(dt)

        // 确保 sample 是 float32
        var sampleFloat = sample.asType(.float32)

        if config.stochasticSampling {
            // x0 = sample - sigma * model_output
            let x0 = sampleFloat - sigmaArr * modelOutput
            let noise = MLXRandom.normal(sample.shape)  // 不再使用 generator
            let nextSample = (1.0 - sigmaNext) * x0 + sigmaNext * noise
            sampleFloat = nextSample
        } else {
            // prev_sample = sample + dt * model_output
            sampleFloat = sampleFloat + dtArr * modelOutput
        }

        // 增加 stepIndex
        stepIndex! += 1

        // 转换回原始 dtype（如果 modelOutput 有特定 dtype）
        return sampleFloat.asType(modelOutput.dtype)
    }

    /// 前向加噪：将干净样本加噪到指定时间步
    /// - Parameters:
    ///   - sample: 原始样本
    ///   - noise: 噪声
    ///   - timestep: 目标时间步
    /// - Returns: 加噪后的样本
    public func scaleNoise(sample: MLXArray, noise: MLXArray, timestep: Float) -> MLXArray {
        // 找到对应的 sigma
        guard let idx = indexForTimestep(timestep) else {
            fatalError("Timestep not found")
        }
        let sigma = sigmas[idx]
        let sigmaArr = MLXArray(sigma)
        // scaled = sigma * noise + (1 - sigma) * sample
        return sigmaArr * noise + (1.0 - sigmaArr) * sample
    }

    // MARK: - Private Helpers

    private func _initStepIndex(timestep: Float) {
        if let begin = beginIndex {
            stepIndex = begin
        } else {
            stepIndex = indexForTimestep(timestep)
        }
    }

    private func indexForTimestep(_ t: Float) -> Int? {
        for (i, ts) in timesteps.enumerated() {
            if ts <= t + 1e-5 {
                return i
            }
        }
        return nil
    }

    // 动态时间移位
    private func timeShift(mu: Float, sigma: Float, t: [Float]) -> [Float] {
        if config.timeShiftType == "exponential" {
            return t.map { _timeShiftExponential(mu: mu, sigma: sigma, t: $0) }
        } else { // linear
            return t.map { _timeShiftLinear(mu: mu, sigma: sigma, t: $0) }
        }
    }

    private func _timeShiftExponential(mu: Float, sigma: Float, t: Float) -> Float {
        return exp(mu) / (exp(mu) + pow(1.0/t - 1.0, sigma))
    }

    private func _timeShiftLinear(mu: Float, sigma: Float, t: Float) -> Float {
        return mu / (mu + pow(1.0/t - 1.0, sigma))
    }

    // 拉伸到 shiftTerminal
    private func stretchShiftToTerminal(t: [Float], terminal: Float) -> [Float] {
        guard let last = t.last else { return t }
        let oneMinusZ = 1.0 - last
        let scaleFactor = oneMinusZ / (1.0 - terminal)
        return t.map { 1.0 - (1.0 - $0) / scaleFactor }
    }

    // 转换为 Karras 噪声调度
    private func convertToKarras(sigmas: [Float], numSteps: Int) -> [Float] {
        let sigmaMin = sigmas.last ?? 0.0
        let sigmaMax = sigmas.first ?? 1.0
        let rho: Float = 7.0
        let ramp = (0..<numSteps).map { Float($0) / Float(numSteps - 1) }
        let minInvRho = pow(sigmaMin, 1.0 / rho)
        let maxInvRho = pow(sigmaMax, 1.0 / rho)
        return ramp.map { pow(maxInvRho + $0 * (minInvRho - maxInvRho), rho) }
    }

    private func convertToExponential(sigmas: [Float], numSteps: Int) -> [Float] {
        let sigmaMin = sigmas.last ?? 0.0
        let sigmaMax = sigmas.first ?? 1.0
        let logMin = log(sigmaMin)
        let logMax = log(sigmaMax)
        return (0..<numSteps).map { i in
            let t = Float(i) / Float(numSteps - 1)
            return exp(logMax + t * (logMin - logMax))
        }
    }

    private func convertToBeta(sigmas: [Float], numSteps: Int, alpha: Float = 0.6, beta: Float = 0.6) -> [Float] {
        // Beta schedule is not yet implemented; using default schedule.
        print("Warning: Beta schedule is not implemented, using default schedule.")
        return sigmas
    }
}
