# D-META-RECIPE-01：版本化配方与隐私投影

规格 1，contract_revision=1，batch_id=D-T0-META-01。源 c808293692eb7be90b7c9de73667c9d7bc327e3a；共同准备提交完整 SHA 在派工 request。run_id=run-v7-initial，证据根 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-META-RECIPE-01/run-v7-initial。Lead 维护规格，预检前不实现。

## 价值与边界

提供真实执行快照的最小可携带数据，公开版本默认不携带提示词。组件可离线编解码和预览投影；本批不做 PNG 嵌入／XMP 互操作、文件导入 UI、C2PA、全媒体管理或项目迁移。不是把 sidecar 当内嵌。只用 Foundation，允许 CryptoKit 做摘要但不读文件/网络，不能从界面/全局配置/机器信息补造来源。

只新增／修改：Packages/UI/Sources/DWorkbench/Media/GenerationRecipe.swift；Packages/UI/Tests/DWorkbenchTests/GenerationRecipeTests.swift。禁止所有其他源码、共享存储／运行时、UI、Package.swift、任务单、Git、源树、应用／模型／用户素材和旧证据。必读：本规格、AGENTS 的数据边界、MULTI_AGENT_WORKFLOW、Sources/DInference/InferenceRequest.swift（仅理解实际参数，不要求持有 ModelReference.directory）、已有 Testing 风格。不要读 Agent 原始日志、账户配置或完整研究。

## 冻结接口与数据语义

- RecipeField<Value: Codable & Sendable & Equatable>：明确 value(Value)/unknown/notApplicable/withheld/invalid(reasonCode: String)，Codable JSON 对象包含 state，只有 value 状态携 value，其余不能伪装空字符串或 null；state 用 value/unknown/not_applicable/withheld/invalid。invalid 原因是受控非敏感短代码，不任意回显原始输入。解码拒绝矛盾组合和未知状态。
- GenerationRecipe：Codable/Sendable/Equatable，assetID UUID、assetVersion UUID、runID UUID；modelSource、modelRevision、weightsManifestSHA256 各 RecipeField<String>；prompt RecipeField<String>、structuredInputRevision RecipeField<String>；seed RecipeField<String>（十进制 UInt64 规范表示）；steps RecipeField<Int>、guidance RecipeField<Double>、width/height RecipeField<Int>；scheduler、computePrecision、quantization、implementationVersion、mediaPayloadSHA256 各 RecipeField<String>；parents [UUID]；声明可信度 RecipeClaim enum captured/callerDeclared（JSON captured/caller_declared）。不把代码 task/run/model 参与者混入媒体；此处 runID 是媒体生成运行。
- seed 以字符串避免 UInt64.max 在其他 JSON 实现中损失；只允许 0 或非零数字开头十进制、无符号/空格/前导零且 <= UInt64.max。整数尺寸/步数正数、guidance 有限且 >=0，bool 不得作为数字。SHA 为64小写十六进制。字符串原 Unicode 保留，不猜值。
- modelSource 是逻辑模型标识（例如 owner/repository），不保存 ModelReference.directory。known value 限不超过256字节的 ASCII 字母/数字/下划线/短横线/点及单个中间斜线，禁止绝对路径、URI、userinfo、query、fragment、.. 路径段。revision/implementation/scheduler/precision/quantization 为非空短标识，不含 URL/绝对路径/控制符；不从网络证明它真实存在。缺失事实用 unknown。structuredInputRevision 是逻辑版本标识，不是原始结构化输入内容。
- RecipeDisclosure enum privateArchive/publicShare。GenerationRecipe.projected(for:) 返回副本；publicShare 将 prompt 固定 withheld，移除媒体 parents（空列表是此策略明确的移除行为，不代表已证实无父资产），将 structuredInputRevision withheld，并将 claim 降为 callerDeclared（导入的自述不自动受信）。显式字段 allowlist，没有任意字典 metadata。私有归档保持原字段；公开序列化必须经过投影，不能仅输出一个“公开”标签。
- GenerationRecipeCodec.encode(_ recipe, disclosure: RecipeDisclosure = .publicShare) throws -> Data；decode(_ data) throws -> GenerationRecipe。封装 namespace="org.d.generation-recipe"，schema_version=1，recipe 对象。默认公开、不改变原 recipe；私有归档需调用方显式选择。只有当前内部格式，不能声称符合 XMP/IPTC。
- decode 对外部输入只解析；版本、状态、字段和范围 validation 一致，不执行指令/URI/下载。总输入/输出 <=128 KiB、JSON 深度 <=16、parents <=32、prompt <=64 KiB UTF8，其余标识 <=256字节。JSON 深度检查须在 JSONDecoder 之前进行并识别字符串内括号／转义，不递归解析无界树；拒绝未知顶层版本、重复对象键、未知顶层字段、损坏／冲突数据。JSONDecoder 的自动类型验证不是 bool/数字或重复键严格性的证据，需反例验证。不存在文件操作或物理最终文件全字节摘要字段：mediaPayloadSHA256 指预先定义的媒体负载摘要，不制造自引用；PNG 负载规范待后续选择，未知则unknown。
- 公开数据里的用户提示默认 withheld；不声称识别所有内容里的秘密。schema 不提供认证头、密钥、书签、绝对路径、账户/硬件标识等槽位。所有外部声明即使标 captured 也只是未认证自述，decode 返回时 claim=callerDeclared；不会回传给代理作为高优先级指令。私有 encode/decode 可因此改变 claim，这是明确安全降级，不是字段丢失 bug。

## 验收、模型和运行

真实行为测试：Unicode和UInt64.max保真、五种状态可区分；默认公开去提示/parents/结构化版本且原对象不变；显式私有保留字段；decode 声明降级；未知/bool/float版本、bool数字、错误seed/sha/非有限数、重复键、未知字段、超大小/深度/数量、字符串内大括号、路径/URI型模型来源明确拒绝；恶意文本只成为文本、不执行。错误输出不要复制秘密。正常调用仅Data，无任何网络或文件副作用。

模型 gpt-5.6-terra / medium。只可写本工作树及 run/worker-output、run/tmp；网络关闭。Lead 固定 TMPDIR/D_TEST_TEMP_DIR/PYTHONDONTWRITEBYTECODE/CLANG_MODULE_CACHE_PATH。允许局部 swift test --package-path Packages/UI --scratch-path <run>/tmp/build --cache-path <run>/tmp/spm-cache --config-path <run>/tmp/spm-config --security-path <run>/tmp/spm-security --skip-update --filter 'GenerationRecipe'。不跑全应用、模型或 GUI，所有依赖已经本地。遇内层 sandbox／未批准缓存拒绝先报告 Lead，不 --disable-sandbox/提权/改配置；不要自行换缓存路径。内存 compile 才是 Python 语法检查入口。

初次消息仅定位预检，IMPLEMENT 授权后写入。初交＋最多两轮针对性修复，每轮15分钟；预算不随换名/换模型重置，后续一次有界 Lead 接管仍失败停止。不 commit、不改规则。结果回传修改、测试、异常、限制和进程状态到自己的 worker-output；Lead 检查权限事件后再决定修复。与 T0 不共享新类型/文件，能独立验收。

## 初交审核与修订 2（冻结行为不变；2026-09-08）

初交文件由 Terra/medium 完成，Lead 尚未改实现。Worker 按调度未编译；Lead 在固定初交提交上串行验证，结果见 run-v7-initial/lead-initial-tests.json/log。T0 初交测试有 Swift await 语法错误；META 初交测试有真实版本接受缺陷及未实际变更输入的负例夹具。测试代码缺陷、产品实现和环境分别归因。

Lead 已检查初次执行事件：修改只在允许文件和自有输出，静态命令退出0，未观察到越界/权限拒绝/网络/安装；子 CLI 结束并交回写入权。Lead 新增只读验收夹具 Packages/UI/Tests/DWorkbenchTests/GenerationRecipeLeadContractTests.swift；不扩大 Worker 修改清单，Worker 不可修改该文件。反例来自原契约，新增的是真实覆盖而非新的产品需求。修复1后仍最多余一次普通修复；不换编号重置。

Lead 帮助为语义说明、反例和测试，未代写实现；具体修复消息/请求SHA/模型写根在 repair-1-prompt.txt/request.json。Swift package 测试仍由 Lead 串行承担；Worker 不得把未执行测试报为通过。
