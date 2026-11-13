# 2026-11-13 SSD 获准清理记录

状态：清理已完成；待用户及独立顾问审阅。仅清理已批准目录，未开始下一轮产品修改。

## 授权、现场与保护

用户在只读盘点后明确批准：175个旧编译缓存；不用且能从源码/输入恢复的旧候选；两套旧TestKit模型；9月30日试用区两套H3副本。当前使用的保留，不可恢复的先报告再决定。本轮没有扩大到其余缓存、工作树、备份卷、主模型库或用户项目。

实际施工树 `Codex/D-Worktrees/D-UI-CONSOLIDATED-20261020`，分支 `codex/ui-consolidated-20261020`。fetch后本地与远端同为 **8b41882a71b3d7e88dea47fc0ec80cc491f4920a**；12个旧App源码提交全部为该远端祖先（逐项退出0）。只提交本报告与证据、调查索引；原有4份未提交收口文档、主树个人scheme未修改或混入本次提交。

Lead唯一写入/删除者；三名只读复核者检查模型映射、旧App恢复输入与删除边界。执行前检查进程及同用户可见的打开文件：无命中删除目标的活动D/构建/模型文件；检查限定于可读进程，不声称穷尽受系统保护的进程。未强退应用、未改变权限、未操作Time Machine、未修改磁盘格式或系统设置。

桌面“D 最新版”实际解析仍指 `CurrentD/Nov6-Models-a9dc46dd/D.app`。该包与新 `CurrentD/Nov13-Closeout-8b41882a/D.app` 均保留，清理后deep/strict签名核验通过；当前receipt、原未提交文档、个人scheme及H3的120B包装摘要不变。新8b仍为未完成原生收口的工程候选，清理不等于产品验收通过。

## 完成结果与实际空间

以下GB为十进制。`du`目录计费包含APFS克隆共享块，**不能当成实际释放量**。

| 范围 | 实际删除 | 目录计费 |
|---|---:|---:|
| 3个历史任务的编译/索引缓存 | 175目录 | 151.510 GB |
| CurrentD的8个旧包＋Sep30的4个旧包 | 12 App | 33.100 GB |
| 两套TestKit的Models | 172文件、2根 | 166.102 GB |
| Sep30两套H3权重闭包 | 76文件、2根 | 288.047 GB |
| 合计 | 191删除根 | 638.759 GB |

同一APFS容器可用空间从 **0.275059 GB** 到 **72.390173 GB**，实测净增加 **72.115114 GB**（约72.12 GB）。这是检查点间净变化，含少量元数据/系统后台变化，不伪称每个目录的独占块精确归因。

缓存阶段净增加约41.41GB，旧App阶段约30.71GB。模型删除阶段未观察到正向净释放，符合它们与保留源共享APFS块的情况；不能再把454.149GB重复计为腾出的容量。未读取私有块映射，故不将“符合共享”升级成逐extent证明。`aroma`备份卷保持原样。

所有191根在清理后实查不存在；保留源124文件删除前后device/inode/size/mtime相同。完整集合见[精确删除清单](removed-paths.json)，空间见[分段检查点](capacity-checkpoints.json)。

## 缓存：范围及恢复

仅 `AgentTrials/D-UI-CONSISTENCY-01`、`D-UI-LOCAL-GLASS-01`、`D-RENDERING-WORKSPACE-01` 内预先列出的175根，类型为 `Intermediates.noindex`、`ModuleCache.noindex`、`CompilationCache.noindex`、`SDKStatCaches.noindex`、`SDKExplicitPrecompiledModules`、`Index.noindex`。

未删除Products、Logs、xcresult、trace、项目、SourcePackages、模型或证据。当前复用的 `run-20261106-model-add-copy/release-ba95fcf8/DerivedData` 与整个当前任务缓存保持。重建/索引会按原工程和工具链再生成缓存，旧中间对象和索引无需逐字恢复；首次构建会变慢。

## 旧App：删除身份与恢复依据

下表路径相对SSD卷根。仅删除 `.app` 本体，父目录小回执、配置、日志、截图/原始trace与QA项目保留。

| 旧App | 准确源码提交 |
|---|---|
| `Codex/D-Development/CurrentD/B9-Followup-1c2f37ed/D.app` | `1c2f37ed525595492e907f4874e9253404b9eb1d` |
| `Codex/D-Development/CurrentD/Nov6-46e23fbe/D.app` | `46e23fbec16715e80fff1046e4c4a8543236b317` |
| `Codex/D-Development/CurrentD/Nov6-Diagnostic-21950944/D.app` | `2195094411a8f6591f690b8cb70864b7927058eb` |
| `Codex/D-Development/CurrentD/Nov6-Models-aebbcffe/D.app` | `aebbcffe57d5e851910905638a8bdc7b98e617fb` |
| `Codex/D-Development/CurrentD/Nov6-Models-ba95fcf8/D.app` | `ba95fcf872fcd6be03ccf9b132d483b98e76d8a1` |
| `Codex/D-Development/CurrentD/Nov6-Models-fac7329a/D.app` | `fac7329a7580fedb1bc62c2b337b7381fa2a5fe2` |
| `Codex/D-Development/CurrentD/Nov6-Retry-3b4ffcd5/D.app` | `3b4ffcd57481320fc0c8cba3c14ca7f7d2ca2275` |
| `Codex/D-Development/CurrentD/Nov6-aff734d3/D.app` | `aff734d339c25e727322baedcee670e69e8a4835` |
| `Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/delivery/budget/D Release Freeze.app` | `6e8d35ec7f593c53b1c54b9829819dd3c1c2fbd7` |
| `Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/delivery/intermediate-9cdf/D Release Freeze Closeout.app` | `9cdf8e51222852ba67bb410929ff0c613511a4a1` |
| `Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/delivery/intermediate-41ad/D Release Freeze Closeout.app` | `41ad63026da948eef6e3b5f5837f63744f1a2c98` |
| `Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/delivery/D Release Freeze Closeout.app` | `b315ffa0c2d8d191204b0b93f1afdaaaae46e865` |

8个CurrentD包的Info源码/产品输入/资源摘要与原build-report对应。`21950944`诊断内容已提交；`ba95fcf8`主回执的复制ENOSPC失败保留，其同目录 `package-recovery.json` 证明随后clone恢复，未将失败改写成初次构建成功。Sep30四包的小执行文件/Info摘要与身份回执对应，六个engine.json与保留的delivery/resources逐字相同。

恢复材料保留：

- 当前任务 `run-20261102-closeout-copy-b6-b8/resources-native-final`、`run-20261106-model-add-copy/resources`；各release目录中的Candidate配置、Info、build/package-recovery回执；`run-20261020-01/packages`、`package-cache`和开发签名配置。
- Sep30 `delivery/resources`、`delivery/ACEEngine`、`prepared-inputs.json`及原六引擎输入；`lead`内构建命令、身份回执和诊断patch；Sep30早期 `run-20260930T070201Z/lead/source-packages`。
- Git源码历史与现有工程树均未删除。恢复需在获准的隔离源码位置使用对应提交/配置/资源正常重建和重新签名；**没有重新构建12包，不承诺原签名二进制逐字还原**。包已不再可直接双击复验旧画面，但原证据保留。

## 两套TestKit和H3：完整可恢复副本

每套TestKit Models恰好86清单文件，83,050,571,478B；两套共166,101,142,956B。八类：Qwen2.5的0.5B/1.5B/7B/32B/72B Q4、FLUX.2-klein4B Q8、Stable Audio3 small-music/medium。保留源为 `Codex/D-Development/Models` 下同名准确目录。

H3两套各38文件，144,023,606,861B；准确revision `42ed227ee7df40d41602854ae760620d6eb651fe`。保留源为 `Codex/D-Development/Models/D-Video-Packs/H3-FL2VA-BF16/model`；原provenance清单SHA256 `5622b0bb6d163f07b5c0556acdb732474011f4fa7240ddaf659d7185ff890d9f`。只删除旧raw根和旧prepared的model子目录，原120B `D-VIDEO-PACK.json`保留。

本轮校验不是只看尺寸：124份保留源均通过原manifest指定摘要（SHA256或正确的Git blob SHA1），248份待删对应文件均按8MiB块与保留源逐字相等，核对完整文件集合、无额外文件/缺文件/符号链接、读取前后身份未变；保留源新增可审计SHA256见[逐文件恢复映射](model-recovery-files.json)。没有重新下载、转换或用低精度替代。校验脚本最初遇到清单字段布局差异（directoryName与catalog、algorithm/checksum与sha256）；只在删除前修正解析，复用已完成且stat/摘要仍一致的记录，最终全部校验成功后才删除模型。

已知两个preview模型索引无这些旧路径；当前D、当前重模型验收输入和实际模型库均保留。不声称扫描了所有用户项目/私有书签。旧试用启动器自己依赖被删Models，因此在两个kit根及Sep30 delivery各留移除/恢复说明，明确旧包现在不能直接离线运行；未改原启动器和历史清单。

恢复方法：按 `model-recovery-files.json` 从retainedSource复制到所需removedIdenticalCopies原相对位置，再核本记录SHA256及原manifest。TestKit只复制各Manifests/catalog列出的文件；H3按38文件闭包恢复，保留原包装，无需重做准备转换。不要将保留源额外provenance/锁文件顺带写入原清单闭包。

## 保留与未扩展范围

- 当前a9/new8b、桌面入口、CurrentD receipt/已保存试用资料、现有QA项目与用户内容。
- TestKit的Results/Inputs/Manifests/Licenses/Runtime/Profiles/Tools/README；Sep30 samples、Qwen、ACEEngine、引擎资源和全部小回执。
- 全部源码/259注册工作树（含9个dirty）、个人scheme；当前exact模型、兼容/转换输入、来源归档；备份卷、系统索引和无权限系统目录。
- 本次获准清单没有发现必须先请用户裁定的唯一/不可恢复内容；因正在使用而保留的current候选与依赖不属于失败。其余未批准大目录没有顺手扩删。

## 证据与交付边界

[汇总机器记录](result.json)与上述三个JSON构成去敏审阅集。原始只读盘点、删除逐项时间、lsof目标匹配、保护摘要、失败解析及完整校验日志保存在本机受控 `storage-cleanup-20261113`，不上传进程总表、私人环境、模型权重或原始用户文件。历史只读盘点保留，不重写当时估算。

本轮没有修改产品、重编译或替换桌面App。清理修复的是存储容量前置，**不关闭任何原生、模型、保存、StoreKit或性能验收事项**。本次提交只含清理报告、必要去敏清单与调查索引；推送既有工作分支，不合并main、不发布。
