import Foundation
import MLX

/// 将 HuggingFace 的键名转换为 Swift 模型的参数路径
func mapSD3Weight(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var newKey = key

    // 替换规则：模式 -> 替换后路径
    let rules: [(String, String)] = [
        // 主模块
        ("pos_embed.", "posEmbed."),
        ("time_text_embed.timestep_embedder.", "timeTextEmbed.timestepEmbedder."),
        ("time_text_embed.text_embedder.", "timeTextEmbed.textEmbedder."),
        ("context_embedder.", "contextEmbedder."),
        ("norm_out.", "normOut."),
        ("proj_out.", "projOut."),

        // Transformer 块（需要处理索引）
        ("transformer_blocks.", "transformerBlocks["),
        ("].norm1.", "].norm1."),
        ("].norm1_context.", "].norm1Context."),
        ("].attn.", "].attn."),
        ("].attn.to_q.", "].attn.toQ."),
        ("].attn.to_k.", "].attn.toK."),
        ("].attn.to_v.", "].attn.toV."),
        ("].attn.add_q_proj.", "].attn.addQProj."),
        ("].attn.add_k_proj.", "].attn.addKProj."),
        ("].attn.add_v_proj.", "].attn.addVProj."),
        ("].attn.to_out.0.", "].attn.toOut."),
        ("].norm2.", "].norm2."),
        ("].ff.", "].ff."),
        ("].norm2_context.", "].norm2Context."),
        ("].ff_context.", "].ffContext."),
    ]

    for (pattern, replacement) in rules {
        if newKey.contains(pattern) {
            newKey = newKey.replacingOccurrences(of: pattern, with: replacement)
        }
    }

    // 处理 transformerBlocks 索引的闭合括号
    if newKey.contains("transformerBlocks[") && !newKey.contains("]") {
        // 提取数字，例如 "transformerBlocks[0." -> 数字 0，然后补上 "]"
        let prefix = "transformerBlocks["
        if let range = newKey.range(of: prefix) {
            let afterPrefix = String(newKey[range.upperBound...])
            if let dotIndex = afterPrefix.firstIndex(of: ".") {
                let numberStr = String(afterPrefix[..<dotIndex])
                if let _ = Int(numberStr) {
                    // 构建新的键名
                    newKey = "transformerBlocks[" + numberStr + "]" + afterPrefix[dotIndex...]
                }
            }
        }
    }

    // 处理 qk_norm 相关（如果存在）
    if newKey.contains("norm_q") {
        newKey = newKey.replacingOccurrences(of: "norm_q", with: "normQ")
    }
    if newKey.contains("norm_k") {
        newKey = newKey.replacingOccurrences(of: "norm_k", with: "normK")
    }
    if newKey.contains("norm_added_q") {
        newKey = newKey.replacingOccurrences(of: "norm_added_q", with: "normAddQ")
    }
    if newKey.contains("norm_added_k") {
        newKey = newKey.replacingOccurrences(of: "norm_added_k", with: "normAddK")
    }

    return [(newKey, value)]
}
