# D-AUDIO-PROJECT-01：统一音频项目与安全迁移

状态：AP1 实施中，隔离候选，未接入生产。2026-09-16 用户批准下一阶段；H22/H23仍等待本人返回，当前仅完成可独立的工程部分。

## 固定基线与目标

源 `fa50c3718ebc46dec479772e5cbdb33058e46d44`（生产代码3898e1d）；HUM `c79ca72a6c300fd3bade7d2f3475ca4baf3140ca`、歌声 `c01d47e1fd8f406b35c2f9a4bdf759c6faaa95d9`。候选 `codex/d-audio-project-01`，外盘独立工作树同任务名。保留双方历史，schema15统一13/14，旧项目原件、人工纠错及歌声条件不丢失；准备一个隔离普通签名测试版集中H22/H23。没有新模型/量化、DAW、I2V、GUI或真人通过声明。旧任务失败、预算及归因保留，不以本编号继续旧实现重试。

源scheme为未暂存个人修改，不改不收录；原D、真实作品、旧候选/证据不修改。机器验收通过后只允许候选及源状态文档提交；H22/H23通过前不接入新产品代码或默认启用。

## AP1冻结契约与行为表

| 原状态/操作 | 必须结果 |
|---|---|
| schema12/13/14打开 | 直接迁移15，一次revision+1；原清单原字节备份project.vN.backup.json，媒体不变；不先中转别的格式 |
| 13歌声 | 保留未完成Unicode草稿、notes/lyrics稳定ID、时间字符串、phrase/content revision、材料ID和用途、任务实际请求和singingDraftRevision、候选选择/采用/拒绝历史；不创建许可同意 |
| 14哼唱 | 保留原声、轨迹、候选/采用/拒绝、noteEdits稳定index、actions及revision（包括撤销后空actions）；过期记录可读但不能用于新操作 |
| 同项目混合 | 新建/保存/关闭/重开两类文档互不覆盖；选中一类不会丢另一类状态；已登记媒体原字节不变 |
| 损坏编辑/资产 | 越界回放、缺失/损坏结果或摘要不符在升级发布前报错，原manifest不变；不能忽略坏记录、默认空日志或先升级再报错 |
| 备份冲突/符号链接、revision溢出、发布前清单被改 | 明确拒绝，外来/既有文件保持；已持久化备份允许保留以恢复 |
| backupDurable / beforePublication抛错 | 原manifest不变，精确备份可用，安全重试 |
| publicationDurable抛错 | 新清单已持久化应可重开；不谎称回滚 |
| 旧读者13/14遇15 | 拒绝且不写清单；不能偷偷丢不认识的字段 |
| unknown16 | 拒绝、无写入 |

Lead拥有ProjectModels/Store/Session与共享装配，合并前审查指出旧迁移先发布再回放的缺口，现改为迁移前及最终发布前强校验。生产算法/音质/既有布局和并发语义不变。schema13只容纳歌声，schema14只容纳人工音符解释，15两者并集；旧格式下新字段不能靠忽略获得通过。v1…11既有迁移继续回归。

## 子任务 TEST / Sol high

task_id D-AUDIO-PROJECT-01-TEST；spec_revision AP1；contract_revision audio-project-15.1；batch_id D-AUDIO-PROJECT-01；实际base_sha/run_id及路由记外部job.json。模型选Sol/high，因为持久化与旧版本反例需要独立理解，不是机械补断言。只一名实现Worker，Lead同时处理共享集成和独立验证；不凑并行。

唯一允许修改：`Packages/UI/Tests/DWorkbenchTests/AudioProjectMigrationTests.swift`（新文件，辅助夹具也放此文件）；不能改生产、旧测试、规格、Package/工程、锁文件、源树或公共Git。阅读本规格、AGENTS关键保护、ProjectModels/ProjectStore相关API、PitchWorkflowTests中pitchCandidate/withPitchFixture与迁移测试、SingingCreationStoreTests中prepare/publishValidResult（仅按需参考）。接口以本次基线代码为准，发现歧义先报Lead。

需实现可独立运行的CPU持久化测试，不只修改JSON头断言版本：构建真实结构化歌声13/哼唱14夹具，明确裁去另一候选不存在的字段；完整比较原/迁移documents/jobs/assets及媒体字节（仅schema/revision/date可变化），精确备份；两类混合保存重开；人工编辑缺失/损坏结果、越界index迁移拒绝且原清单不变；13与14备份冲突/检查点失败/恢复；beforePublication改清单应拒绝；旧版本字段互相冒充拒绝。包含实际noteEdits、实际完成候选/采用状态和partial singing草稿，不只空项目。尽量参数化，不镜像实现逻辑；测试命名说明语义。旧读者真实二进制拒绝由Lead另做，不在本文件模拟旧算法。

执行先只读PRECHECK；核实际目录/HEAD/branch/commonGit/模型强度/写根后才IMPLEMENT。同一受限CLI workspace-write，网络false；写根仅自身工作树、run/TEST/output及tmp，共享Git不可写。不递归、不commit、不改验收政策；输出摘要/异常/自有进程状态交回。允许读源码、写指定测试，Swift前端parse（显式module-cache-path在tmp）和内存compile检查自身辅助Python，禁止默认py_compile。CPU行为测试由Lead串行执行，Worker不运行全构建/GPU/GUI/模型或下载安装。

缓存/输出/TMPDIR均在任务run/TEST；未预授权拒绝暂停报告，不自行换权限/目录。唯一预先允许降级：Swift parse若仅modulecache缺省路径拒绝，先报告证据并使用上述明确tmp一次；其他未知副作用停。初交+最多两轮针对性修复，必要一次有界Lead接管，非实现者复核重要Lead修改；每轮前检查异常与保护。新任务预算不刷新HUM/歌声旧预算。

## 验收/证据与恢复

外部持久证据：D-Development/AgentTrials/D-AUDIO-PROJECT-01/run-20260916T065900Z。请求、路由、进程、测试结果、保护与最终receipt放此，不存大日志/媒体入Git。
Lead：全UI包CPU/离屏宿主（3个旧条件skip单列）、旧读者拒绝15、迁移/混合数据、基础核回归、普通签名独立App编译及只读签名确认；复用未变算法真实模型证据，不冒称此次重跑。模型库和旧文字/图像/音频/视频入口组合CPU回归不得降低门槛。需要原生授权/IME/试听的H22/H23仍未执行。最终写受测代码SHA、文档差异、候选SHA和源状态文档SHA；自身提交SHA只写外部回执。

恢复先核源fa50/个人scheme及候选真实HEAD、活动Worker/进程、规格revision和权限。旧候选不动；未通过人验收不合入生产。来源：旧Sol/Terra/Lead贡献依原任务保留；本批共享集成/迁移Lead，新增测试Sol，非实现者只读审核不等于独立执行。完整Lead用量及订阅费用unknown，不重算历史累计快照。

## 2026-09-16 AP1机器验收完成：同版H22/H23待本人返回

本轮独立工程目标已完成：两候选保留历史合并、schema15直接兼容12/13/14、损坏人工编辑在发布前强校验、同项目两类内容保存重开及旧读者保护通过。生产源仍3898e1d，未默认启用/未合入源产品代码；H22/H23未执行，不能称全部音频产品验收完成。候选最终文档SHA与源状态文档SHA见本run `final-receipt.json`。

### 版本与证据

- 合并提交637de6a5ce2a1728ef6011673fd33ccf4f4b8e74保留HUM/歌声历史。准备51ea50b22f2bc2d2dd96f7f2291a747e6f89b9f9补显式return并冻结AP1；后续仅新增/修正专项测试。
- 完整最终受测 **4a07add226d9c298aead64f9221f06ad694ed432**；相对51ea50b仅`AudioProjectMigrationTests.swift`不同，生产代码完全相同。最终结案仅本任务及三份现有状态文档，不谎称新文档提交重新测试。
- 证据根 `D-Development/AgentTrials/D-AUDIO-PROJECT-01/run-20260916T065900Z`；下列均相对此根。

| 检查 | 本次结果与边界 |
|---|---|
| 最终完整UI package | `lead/combined-cpu-final/result.json`，4a07add，exit0、64.496秒；DWorkbench报告434项，其中3个既有文字模型条件项跳过，其余无失败；UI104、ModelLibrary23无失败。新增迁移12方法含参数化反例，不叠加历史运行计数。离屏宿主不冒称GUI |
| 专项初交及返工 | a5a9fda初交11方法通过，但审阅指出最终发布前结果变更和坏JSON/摘要混杂两缺口；Sol一次repair1后新增直接反例、让坏JSON摘要匹配，4a07add完整回归通过。没有修改生产契约或放宽断言 |
| 基础核心 | `lead/foundation/result.json`，51ea50b，66项通过；后续生产/核心不变 |
| 真实旧读者 | `lead/legacy-readers/results.json`：从固定歌声c01d47e、HUMc79ca72源码分别编译真实读者；各自读取结构化13/14夹具成功且全树不变；迁移及混合15被两读者明确拒绝且全树不变；当前读者重开混合15不变 |
| 历史真实生成作品副本 | `lead/historical-singing/results.json`：读取此前真实两次歌声的13项目副本，实际旧13打开、15迁移、旧读者拒绝；歌声媒体/任务记录/文档完整，精确备份，历史证据原树摘要不变。本轮没有重新运行模型 |
| 普通开发签名编译 | `lead/ordinary-build/result.json`，51ea50b，exit0、58.120秒；原身份/配置，独立DerivedData，未更改Team、bundleID、entitlements或普通D |
| 双引擎封装 | `lead/package-pitch-report.json`与`package-singing-report.json`：既有固定引擎复制到新App，内嵌provider与候选源码逐文件一致；不含新下载/声库资格代确认；此专用产物只打包Pitch/Singing，未重新打包其他模态引擎 |
| 正式部署读取器与签名 | `lead/resolver-run/result.json`实际正式BundledAudioEngine同时resolve/confirmUnchanged两引擎；`lead/signature/results.json`诊断＋直接codesign deep strict通过，Info/signature first-test.D相同、sandbox=true、开发证书链。非实际沙盒运行、公证、TCC或分发验收 |

完整受测版本和App装配版本的映射见`lead/build-version-map.json`。构建保留既有测试UserDefaults的Sendable警告，未以批量标注修改无关代码。初次完整回归及专项检查亦保留，不拿它们覆盖最终版本。

### 来源、审阅与失败经验

Lead实现共享合并/schema15/预发布验证；新增测试由受限 **gpt-5.6-sol/high** 编写，初交＋一轮修复，没有Lead实质重写测试。线程`01a0a90a-cdd2-7630-b81f-7fce7f2ef780`，实际写根为TEST独立树及其output/tmp，共享Git只读、网络false；每轮请求与turn_context一致，服务端隐藏解析unknown。preflight/implement/repair1进程exit0，约34.731/568.356/108.028秒，记录不等于任务整体用时；原始usage快照保留但不求和（resume累计归属未核实），cache输入不重复加，完整Lead及订阅费用unknown。旧歌声/HUM的Sol/Terra/Lead贡献及失败维持原记录，不归给新测试Worker。

两个非实现者只读审阅：`/root/singing_license_resolution`核迁移和两边关键生命周期保留；`/root/singing_repo_integration_scope`指出两项测试缺口并复核4a07add关闭。他们未另行跑测试；实际验证由Lead执行。简要证据`lead/reviews.json`。

异常如实保留：初交一次rg查不存在Packages/Inference返回2，没有权限拒绝或越界写入；空白搜索exit1只是无匹配。Lead历史项目初次探针预期revision+1失败，因为先运行的旧13读者对遗留cancelled无output任务补入既有恢复错误，使revision先+1。修正外部探针，在旧13恢复后另取纯迁移基线，再验证15只变schema/revision/date；不删旧失败副本、不改生产恢复、不声称取消产物已恢复。原历史目录未改。经验：区分格式迁移和正常打开的任务恢复，并在正确边界取快照；另需让坏JSON反例跨过摘要校验才能证明解析失败保护。

### 集中待办与恢复检查点

统一专用测试版：本run `lead/D Audio Unified.app`（只内部评估，未启动/替换普通D）；原始build仍保留。H22本人返回后在隔离项目完成真实材料用途窗口、歌词中文组字缩放和正式歌声试听；Lead执行实际生成/候选处理/保存重开/导出。H23同一App完成实际音符纠错/删除撤销、普通试听/停止、MIDI、安全重开与默认沙盒缓存路径检查。签名/CPU不替代这两项，不重复催解锁或重测已关闭的麦克风项；资格对话框不能代替材料分发许可。

源起点fa50c3718ebc46dec479772e5cbdb33058e46d44；个人scheme SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、index blob9c76916bdc97c2d4298cefe64e0b0fae3380573e、未暂存orderHint1→6保留。普通D关键文件摘要/大小/mtime、两个原候选HEAD与清洁状态、源索引/剩余差异在最终回执复核。全部本轮自有执行进程结束；不把归档当清理，没有后台无限继续。恢复先核真实源/候选/个人修改及回执，勿只用本段历史SHA。

下一步仍是一次性H22/H23同版验收，通过后按既有规则隔离整合最新源并接纳/推送产品代码。下一产品阶段建议按首发目标处理I2V有限缺口，再做一个真实跨模态能力组合；不扩完整音乐编辑器，不在本轮提前启动。当前只推送源状态文档，候选代码保留本地。
