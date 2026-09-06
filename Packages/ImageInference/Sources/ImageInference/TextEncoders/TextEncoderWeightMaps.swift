//
//  TextEncoderWeightMaps.swift
//  ImageInference
//
//  Created by lfrledh on 3/9/26.
//

import Foundation
import MLX
import Core

/// 将 Hugging Face CLIP 文本模型的权重键名映射到 Swift 模型的参数路径
public func mapCLIPWeights(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var mappings: [(String, MLXArray)] = []

    // 处理嵌入层
    if key == "text_model.embeddings.token_embedding.weight" {
        mappings.append(("embeddings.tokenEmbedding.weight", value))
    } else if key == "text_model.embeddings.position_embedding.weight" {
        mappings.append(("embeddings.positionEmbedding.weight", value))
    }
    // 编码器层
    else if key.hasPrefix("text_model.encoder.layers.") {
        let pattern = #"text_model\.encoder\.layers\.(\d+)\.(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              match.numberOfRanges == 3 else {
            return mappings
        }

        let layerIdx = String(key[Range(match.range(at: 1), in: key)!])
        let subKey = String(key[Range(match.range(at: 2), in: key)!])

        // 根据 subKey 映射到 Swift 模型的参数路径
        switch subKey {
        case "self_attn.q_proj.weight":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.qProj.weight", value))
        case "self_attn.k_proj.weight":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.kProj.weight", value))
        case "self_attn.v_proj.weight":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.vProj.weight", value))
        case "self_attn.out_proj.weight":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.outProj.weight", value))
        case "self_attn.q_proj.bias":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.qProj.bias", value))
        case "self_attn.k_proj.bias":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.kProj.bias", value))
        case "self_attn.v_proj.bias":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.vProj.bias", value))
        case "self_attn.out_proj.bias":
            mappings.append(("encoder.layers.\(layerIdx).selfAttn.outProj.bias", value))
        case "layer_norm1.weight":
            mappings.append(("encoder.layers.\(layerIdx).layerNorm1.weight", value))
        case "layer_norm1.bias":
            mappings.append(("encoder.layers.\(layerIdx).layerNorm1.bias", value))
        case "mlp.fc1.weight":
            mappings.append(("encoder.layers.\(layerIdx).mlp.fc1.weight", value))
        case "mlp.fc1.bias":
            mappings.append(("encoder.layers.\(layerIdx).mlp.fc1.bias", value))
        case "mlp.fc2.weight":
            mappings.append(("encoder.layers.\(layerIdx).mlp.fc2.weight", value))
        case "mlp.fc2.bias":
            mappings.append(("encoder.layers.\(layerIdx).mlp.fc2.bias", value))
        case "layer_norm2.weight":
            mappings.append(("encoder.layers.\(layerIdx).layerNorm2.weight", value))
        case "layer_norm2.bias":
            mappings.append(("encoder.layers.\(layerIdx).layerNorm2.bias", value))
        default:
            break
        }
    }
    // 最终层归一化和投影
    else if key == "text_model.final_layer_norm.weight" {
        mappings.append(("finalLayerNorm.weight", value))
    } else if key == "text_model.final_layer_norm.bias" {
        mappings.append(("finalLayerNorm.bias", value))
    } else if key == "text_projection.weight" {
        mappings.append(("textProjection.weight", value))
    }

    return mappings
}

/// 将 Hugging Face T5 编码器的权重键名映射到 Swift 模型的参数路径
public func mapT5Weights(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var mappings: [(String, MLXArray)] = []

    // 处理嵌入层
    if key == "shared.weight" {
        mappings.append(("embedTokens.weight", value))
    }
    // 编码器块
    else if key.hasPrefix("encoder.block.") {
        let pattern = #"encoder\.block\.(\d+)\.(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              match.numberOfRanges == 3 else {
            return mappings
        }

        let layerIdx = String(key[Range(match.range(at: 1), in: key)!])
        let subKey = String(key[Range(match.range(at: 2), in: key)!])

        // 根据 subKey 映射
        if subKey.hasPrefix("layer.0") { // Self-Attention
            let attnSubKey = subKey.replacingOccurrences(of: "layer.0.", with: "")
            switch attnSubKey {
            case "layer_norm.weight":
                mappings.append(("blocks.\(layerIdx).layerNorm.weight", value))
            case "layer_norm.bias":
                mappings.append(("blocks.\(layerIdx).layerNorm.bias", value))
            case "SelfAttention.q.weight":
                mappings.append(("blocks.\(layerIdx).attention.q.weight", value))
            case "SelfAttention.k.weight":
                mappings.append(("blocks.\(layerIdx).attention.k.weight", value))
            case "SelfAttention.v.weight":
                mappings.append(("blocks.\(layerIdx).attention.v.weight", value))
            case "SelfAttention.o.weight":
                mappings.append(("blocks.\(layerIdx).attention.o.weight", value))
            case "SelfAttention.relative_attention_bias.weight":
                mappings.append(("blocks.\(layerIdx).attention.relativeBias.embedding.weight", value))
            default:
                break
            }
        }
        else if subKey.hasPrefix("layer.1") { // Feed-Forward
            let ffSubKey = subKey.replacingOccurrences(of: "layer.1.", with: "")
            if ffSubKey.hasPrefix("DenseReluDense.") {
                let denseSubKey = ffSubKey.replacingOccurrences(of: "DenseReluDense.", with: "")
                // 根据 is_gated_act 决定映射，这里假设 T5Config 中有 isGatedAct 字段
                // 若 isGatedAct 为 true，则使用 wi_0 和 wi_1
                switch denseSubKey {
                case "wi.weight":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi.weight", value))
                case "wi.bias":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi.bias", value))
                case "wi_0.weight":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi0.weight", value))
                case "wi_0.bias":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi0.bias", value))
                case "wi_1.weight":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi1.weight", value))
                case "wi_1.bias":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wi1.bias", value))
                case "wo.weight":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wo.weight", value))
                case "wo.bias":
                    mappings.append(("blocks.\(layerIdx).ff.dense.wo.bias", value))
                default:
                    break
                }
            } else if ffSubKey.hasPrefix("layer_norm") {
                if ffSubKey == "layer_norm.weight" {
                    mappings.append(("blocks.\(layerIdx).ff.layerNorm.weight", value))
                } else if ffSubKey == "layer_norm.bias" {
                    mappings.append(("blocks.\(layerIdx).ff.layerNorm.bias", value))
                }
            }
        }
    }
    // 最终层归一化
    else if key == "encoder.final_layer_norm.weight" {
        mappings.append(("finalLayerNorm.weight", value))
    } else if key == "encoder.final_layer_norm.bias" {
        mappings.append(("finalLayerNorm.bias", value))
    }

    return mappings
}
