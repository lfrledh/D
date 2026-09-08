# T0 工作台有限闭环

2026-09-08 用户本轮目标已批准；source_base=6735266933773adaee33b3a66a01b09c0b1f7d9b，prior_tested=c3197ad9cdade3d486a4153418cacc39af85bc81。旧审核/完整回执已核对，最后仅10份文档变化，scheme未暂存原内容不变。batch_id=D-T0-WORKBENCH-01，contract_revision=1。Lead独占本记录和共享接线，使用当前已验收受限CLI机制，不再做机制试点。

## 最小行为表（冻结）
| 事件 | 结果 | 必须拒绝的反例 |
| --- | --- | --- |
| 新建文字文档 | 同一.dproject内命名文稿、独立id/revision；既有图像文档保留 | 将模态改为独立顶层项目/覆盖旧项目 |
| 选择文字并改写 | UTF16 Character边界，捕获文档id/revision、选区和选择代次；原文不变，流出仅显示候选 | 半surrogate、ZWJ/组合字符内部；延迟编辑回调写入其他文档 |
| 生成中改原文/换选区 | 保留实际用户编辑；旧候选可查看但不再接受，即使选区改回也不复活 | 将旧结果直接应用到当前同样长度的选区 |
| 接受/拒绝/撤销 | 明确接受才替换；拒绝不改原文；仅未后续人工编辑时可撤销最近接受 | 跨版本/文档接受；旧撤销覆盖新输入 |
| 生成/待处理候选时导航 | 有限首版提示先取消并等清理，或接受/拒绝候选；不静默丢弃 | 切文档/项目把结果送给新对象 |
| 保存与关闭 | 自动去抖＋显式保存，写入序列化；导航/关闭flush最新原文。失败保留内存、阻止离开并可重试 | debounce取消导致已排队写入丢失、旧snapshot回写、失联回落内盘 |
| 重开 | 正文、id/revision在原项目恢复；选择/候选/撤销不跨关闭持久化，关闭前需处理候选 | 宣称候选或撤销已永久保存 |
| 取消/错误 | 沿用TextDraftSession，直到outcome清理完成保持busy，错误不形成候选 | 关闭UI即放弃后端handle |

采用项目schema3明确image/text文档，v1/v2原始字节各自备份后升级；不改媒体或签名。格式迁移在候选完成验收前不得用于用户项目。图像入口/既有工作台逻辑持续回归。文本模型由App装配现有MLXTextBackend，与图像共用runtime/重推理许可；本轮只准已批准固定Qwen2.5-0.5B-Instruct-4bit及revision，用户选择现有目录，无安装/下载。保留security scope至取消清理后，模型登记独立于图像安装器；不为本轮重建通用模型平台。

## 分工和验收

D-T0-STORE-01负责限定项目值类型/存储及migration测试；D-T0-VIEW-01负责新文字视图/原生选区桥及对应测试。各自独立工作树、精简规格、gpt-5.6-terra/medium，网络关闭，初交+最多2修复；Lead负责ProjectSession/WorkbenchModel/App装配、共享文件和集成测试。重要Lead实现由非实现者只读审核，最多2子执行/评审同时活跃。无需为并行新建包或空类型。

CPU：原工作台117/核心17回归＋新增存储/选区/协调/保存失败反例，旧schema断言只有从2更新到当前3的明确演进，不删原保护断言。全应用隔离DerivedData及已存在依赖，代码签名关闭只证明编译，不证明运行签名。真实当前模型和GUI必须确认用户D/GPU无争用及独立会话/项目；不能则保留整个候选批次，不将schema3/新UI默认接入源或安装普通D。GUI查询本轮曾长时间超时，未知资源/权限不靠重签或关应用解决。

证据 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908；普通源个人scheme不入任务树。输出/缓存/临时归各自run。无网络下载/签名/权限/依赖修改/推送/main操作/清理。只对自有进程限时回收。到此产品检查点停止；音乐/HUM紧接独立数据/普通试听路线，不等文字高级功能，META PNG另包。

Lead实现清单补充：新增DWorkbench/Text/ProjectTextController.swift及其CPU协调测试；新增DWorkbench/Models/FixedTextModel.swift与已存在fixtures/text-model.json的资源副本，用于固定本地模型只读校验，不引入下载/依赖/新精度。Lead负责选择代次、写入排队和关闭保护，后续非实现者审核这部分重要实现。
