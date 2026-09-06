import Foundation

public struct VAEConfig: Codable, Sendable {
    public var inChannels: Int
    public var outChannels: Int
    public var blockOutChannels: [Int]
    public var layersPerBlock: Int
    public var latentChannels: Int
    public var normNumGroups: Int
    public var scalingFactor: Float
    public var shiftFactor: Float?
    public var actFn: String
    public var downBlockTypes: [String]
    public var upBlockTypes: [String]
    public var midBlockAddAttention: Bool
    public var useQuantConv: Bool
    public var usePostQuantConv: Bool

    public init(
        inChannels: Int = 3,
        outChannels: Int = 3,
        blockOutChannels: [Int] = [128, 256, 512, 512],
        layersPerBlock: Int = 2,
        latentChannels: Int = 16,
        normNumGroups: Int = 32,
        scalingFactor: Float = 1.5305,
        shiftFactor: Float? = 0.0609,
        actFn: String = "silu",
        downBlockTypes: [String] = ["DownEncoderBlock2D", "DownEncoderBlock2D", "DownEncoderBlock2D", "DownEncoderBlock2D"],
        upBlockTypes: [String] = ["UpDecoderBlock2D", "UpDecoderBlock2D", "UpDecoderBlock2D", "UpDecoderBlock2D"],
        midBlockAddAttention: Bool = true,
        useQuantConv: Bool = false,
        usePostQuantConv: Bool = false
    ) {
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.blockOutChannels = blockOutChannels
        self.layersPerBlock = layersPerBlock
        self.latentChannels = latentChannels
        self.normNumGroups = normNumGroups
        self.scalingFactor = scalingFactor
        self.shiftFactor = shiftFactor
        self.actFn = actFn
        self.downBlockTypes = downBlockTypes
        self.upBlockTypes = upBlockTypes
        self.midBlockAddAttention = midBlockAddAttention
        self.useQuantConv = useQuantConv
        self.usePostQuantConv = usePostQuantConv
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inChannels = try container.decode(Int.self, forKey: .inChannels)
        outChannels = try container.decode(Int.self, forKey: .outChannels)
        blockOutChannels = try container.decode([Int].self, forKey: .blockOutChannels)
        layersPerBlock = try container.decode(Int.self, forKey: .layersPerBlock)
        latentChannels = try container.decode(Int.self, forKey: .latentChannels)
        normNumGroups = try container.decode(Int.self, forKey: .normNumGroups)
        scalingFactor = try container.decode(Float.self, forKey: .scalingFactor)
        shiftFactor = try container.decodeIfPresent(Float.self, forKey: .shiftFactor)
        actFn = try container.decode(String.self, forKey: .actFn)
        downBlockTypes = try container.decode([String].self, forKey: .downBlockTypes)
        upBlockTypes = try container.decode([String].self, forKey: .upBlockTypes)
        midBlockAddAttention = try container.decode(Bool.self, forKey: .midBlockAddAttention)
        useQuantConv = try container.decodeIfPresent(Bool.self, forKey: .useQuantConv) ?? false
        usePostQuantConv = try container.decodeIfPresent(Bool.self, forKey: .usePostQuantConv) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case inChannels = "in_channels"
        case outChannels = "out_channels"
        case blockOutChannels = "block_out_channels"
        case layersPerBlock = "layers_per_block"
        case latentChannels = "latent_channels"
        case normNumGroups = "norm_num_groups"
        case scalingFactor = "scaling_factor"
        case shiftFactor = "shift_factor"
        case actFn = "act_fn"
        case downBlockTypes = "down_block_types"
        case upBlockTypes = "up_block_types"
        case midBlockAddAttention = "mid_block_add_attention"
        case useQuantConv = "use_quant_conv"
        case usePostQuantConv = "use_post_quant_conv"
    }
}
