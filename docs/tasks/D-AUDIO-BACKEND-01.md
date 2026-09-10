# D-AUDIO-BACKEND-01 — 音频推理与跨配置扩展

状态：组合工程与既有图文回归通过；真实音频待许可/环境验收，保留候选，2026-09-10。用户授权本阶段实施、测试、集成与 GitHub 工作分支推送。源基线 beaaaf82d845e672c6a3b661d928654affc00518；本文件后续记录完整执行版本。

目标：模型驱动的音频生成／参考变体／区间重绘后端；将本机测试规格与产品可扩展模型/资源政策分离。优先小模型本机真实验收，大配置必须标明适配与待实测，不更改既有 FLUX q8、Qwen 4-bit 精度。音频具体模型及精度在核实官方代码/许可后冻结，不把研究资料当本机实测。

本批不做传统 DAW、乐谱排版、歌声模型全家桶、手机、录音权限、签名或旧音频 schema4 默认接纳。H09/H10 与后端文件输入独立。录音/用户 D/现有作品/源 scheme/旧证据保持。没有安全资源窗口时真实 GPU 项记缺口，不能冒充通过或启用未验收产品路径。

协作：Lead 管契约和集成；每任务初交+最多两轮针对性修复，之后可一次有界 Lead 接管；重要 Lead 实现需非实现者审核。至多两名活跃子执行/审核；独立受限 CLI 工作树，网络关闭，共享 Git 由 Lead 管。当前只读模型选择核验与资源 Worker 预检可并行。

证据：D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T123045Z。保护/源快照见 preparation.json。进程枚举被当前沙箱拒绝，旧任务终止依据已有回执；未声称全系统空闲或写锁。

初始计划（历史）：SCALE 预检→实现，Lead 冻结音频模型与数据契约，再派后端。所有未验收项与实际限制留在本记录。

## Shared audio value contract (Lead, AUDIO1)
AudioRequest/AudioSourceReference/AudioEditRegion add a value-only audioGeneration input. Source-frame half-open coordinates, immutable hash/metadata and operation-dependent validation; backend must still validate actual media/model limits. Existing tasks view exhaustiveness is updated only to return prompt, not enable audio submission or project schema4. This code needs core/combined tests and nonimplementer review.

## Lead checkpoint 2026-09-09 (in progress)
SCALE Sol/high first delivery831.582s, eight allowed files; Lead read changes and core23 tests passed. Candidate3f18d6ce0377dc90fedeef037be136ccbcc121a7, metadata22 tests first failed due Lead test launch not forwarding D_TEST_TEMP_DIR (default/var symlink); configured xctestrun reuse passed original22 methods, zero skips/failures. Evidence scale-mlx-cpu-first, scale-mlx-cpu-configured, scale-core-first. No GPU or ordinary D launch. Isolated batch mergef40cfd8 includes candidate, not source acceptance.
AudioAUDIO1 values were Lead code atd528fc0d; priorcore17 passed (no new audio behaviors yet). Python task precheck identified protocol ambiguity; Lead spec2 specified fields but miscounted4weights as5. First implementation531.267s paused without retained code; Worker also inspected wrong research-archive provenance rather than shipped Vendor manifest. Spec3 corrects4weights and explicit vendoredroot/SHA; prior attempt retained, no accepted implementation/ordinary repair consumed. Runtime precheck correctly identified4/5 mismatch; spec2 corrects beforeimplementation. Both same Sol/high/no-network/externalwrite roots independently observed. Current workers may be active; inspect process receipts, do not edit their files concurrently.
Pinned SA3 code779434a908193105335fd8d833418603625b2859 MIT subset, optimized modelda6edc54ddba10bfd79a077102ded687f80e882b manifests fourfiles each: smallmusic/SFX1,919,674,322bytes, medium6,883,369,494bytes. These are download totals, not RAM. Weights notdownloaded. H11 license pending (https://huggingface.co/stabilityai/stable-audio-3-optimized/blob/main/LICENSE.md and https://ai.google.dev/gemma/terms). Python3.12.14 arm64 bundledruntime exists, numpy2.3.5 present; mlx/sentencepiece notinstalled, no installation performed. Readonly metadata is not inference.
Qwen1.5/7/32B pinned manifests/config4bit/group64/apache2 metadata prepared at eaaab0d8bf4b2da3f9f081757b1293933bfbbcfb; actual files/identities in text-catalog-research. Attempt to download1.5B was rejected by automatic approval review citing old no-download authorization; command entirely unexecuted, no alternate attempt. H12 asks explicit scope. H13 resourcewindow unknown; no process/IORegistry escalation, vm_stat not GPU ownership proof.
Lead prep helper initialUTF8 direct parser reported SyntaxError twice despite same bytes tokenization/compile success; ASCII escaped equivalent ran. Rootcauseunknown, no code ran on parsefailure, no permissionschanged. No source/path fallback. This is a Lead environmentevent, not Worker failure. No historical usage recalculation; eachrun rawincrementalusage retained, serverhiddenresolution/completeLead/subscriptioncost unknown.
Resume: sourceHEADbeaaaf82d845e672c6a3b661d928654affc00518, schemeSHAca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c onlyunstaged, sourceindexclean. Active Python/runtime CLI ownedrunfiles; SCALEended. Textprofiles worker still not launched, firstdelivery/repairsnotconsumed. Next: finish CPU adapters/registration, review and combine exact SHAs, license/download/GPU gates independent. No sourceff/pushyet; do not call stagecomplete.

## Real existing-model checkpoint (Lead, 2026-09-09)
User confirmed currentD/AI/GPUidle. IsolatedCLI built from c57bb6c388771b2d041f0736a001563d7b073cf0, no signing/settings/application changes. Existing text0.5B verifier complete=true/passed=true,10 cases including5 repeatedruns/cancel/signals/brokenpipe; MLX active/cache0 afterallreleases, no growth. Existingimageq8 verifier complete=true/passed=true,17 cases including3 repeated512² outputs/cancel/signals/brokenpipe. Three generatedPNG identicalSHA1743b94c4aab0365a131de5c82d6b5df46eafe3857e78497feff395a0044d8d9, elapsed43.024/40.931/40.987s, peakMLX6,207,522,060bytes, active/cache0 afterrelease. Lead viewedfox/snow image and observed plausible orientation/color/content; this is not artisticqualitycertification. These are actualmodel runs, notaudio proof; upstreamfixed image+textprecision maintained. Both verifierparentandownedchildrenended, no userDclosed. H13 currentwindow resolved, H11/H12 stillpending.
CPU nativeAVAudioFile crosscheck decoded all4410 stereo44.1kHzfloat32 frames exactly, sourceSHA unchanged; syntheticfixtureonly/noplayback (wav-native-cpu/result.json). Existing0.5B CPUchecksum test11methods passed, no skipped, weightsunchanged. Common30methods passed at9e546ebfa3e0bf8b05186694d298a2e212179b3d; runtimeWorker was active but only backend/CLI changes, common/test inputs retained exact committed hash (AudioRequestTests bd60121f81072e87ed7f34f32a1efa385eed8259be8a416a4bb2f7e526bb37a4); combination will be rechecked after pause.
Audio repair1CPU18 passed642413934880ae2d06237b05ea847740328dd351, but independent cachedcodefixture loaded99 insteadverifiedsource1 under-B whileSHA unchanged. Preservedfailure, spec5 grants finalordinaryrepair on exactsource execution and honestunknownmetrics. Runtime repair1productiontypecheckpassedbutfulltestbuildfailed selfcapture initializer; finalordinaryrepair spec4 also clarifies frozenmetadata comparison andframe rounding. NoLeadproductionrewrite yet. Source remainsbeaaaf82d845e672c6a3b661d928654affc00518 withschemeSHAca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c unstaged/indexclean. This checkpoint is not acceptance of pendingaudio or currentbatch-sourceintegration.

## Final candidate checkpoint (2026-09-10 JST; real test timestamps 2026-09-09 UTC)
Combined testedcode d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407 contains reviewed SCALE3f18d6c, TEXT tested7ef7f8a/docs e21e45d (fullsource in text/lead-integration.json), Python tested d9def7ce5a56e10e853a76407aa50548da8f6af0/docs ae02af00, Runtime tested d610184fa2a484d1da89cf5f3543ea347fc34df3/docs e887e55. Full candidates in per-task lead-integration.json and Git parents, not invented shortSHA expansions. Final candidate after this entry is docs-only, fullSHA in external final-candidate-receipt.json; no claim tests ran on a not-yet-created doccommit.

| Check on combined code | Actual result | Evidence relative to this run |
|---|---|---|
| Python memory compile / unittest | 4 source files compile;21 methods passed | combined-acceptance/python-*-result.json / python-tests.stderr |
| Core |30 methods/4 suites passed|combined-acceptance/swift-core-*|
| UI/workbench package |174 methods reported;173 executed passed,1 optional existingweights check skipped,0 failures|combined-acceptance/swift-workbench-*|
| Swift host/image CPU |42 methods/3 suites,100 expanded passed;0 fail/skip|combined-cpu-complete-selection/{summary.json,result.json}|
| Cross-language AUDIO1 | actualSwiftCLI→actualPythonvalidation/publication with explicit synthetic engine/fourfakeweights;generate/variation/inpaint3 pass,large seed/Unicode/frozenmetadata/12288frames/source unchanged/outsideinterval samples exact |combined-audio-bridge/results.json; no real MLX/model |
| Application/CLI assembly |offlinecached dependencies, no-signing builds passed, no launch|combined-acceptance/{app-build,cli-build}-result.json|
| Existing0.5B4-bit text CLI |10 cases complete/pass,fullprocess cancellation/signals/repeats|combined-existing-models/text/summary.json|
| Existing4Bq8 image CLI |17 cases complete/pass,512² repetitions/reference/cancellation/signals/release|combined-existing-models/image/summary.json|
| Expanded image |768x512 truePNG,4steps/guidance1/seed42,52.710s,MLXpeak6309409880bytes,releaseactive/cache0;PNGsha f65f041fe9145298fed3065c65c1ac7f759de62d4c8432b3f1852464ba074a47,Leadvisualchecked|combined-existing-models/{wide-report.json,wide-check.json,wide-visual-review.json}|

Validation harness correction: first combined selector used LocalImageInventoryTests instead of actual LocalImageModelInventoryTests, therefore only27 methods were selected/passed. Lead compared xcresult count, corrected selector and reran full42 on identicalcode afterGPU ended; no assertion/source change. Prior standalone20/40/22 and current27/42 results overlap and are not summed. Optionalweighttest already independently passed on exactunchanged textcode with actual0.5B path (text-existing-check11methods); current174 report still honestly retains skip. No history failure rerun/count inflation.

Source attribution: Sol/high initial implementations; SCALE831.582s andTEXT1342.690s no ordinary repairs/noLeadprodrewrites. Python retained initial900s timeout and2repairs759.631/500.011s (plus earlier531.267s clarification attempt). Runtime initial900s timeout,2repairs1455.988/1205.292s then oneboundedLeadfix of missinginpaintmetadata+partialmetric coordination; nonimplementerSol/high read-only229.699s ACCEPT. Initialdevelopment failures/Leadclarifications/deniedcache/macro events remain per-taskrecord. Main Lead compiled/tested/reviewed/integrated; no claim independentReviewer ran tests. Request/observablemodel+effort+roots in per-runrecords; hiddenserverresolutionunknown. Raw per-turn usage events preserved, not summed as if every resume snapshot were incremental; fullLead/subscriptioncostunknown, no cost-optimal claim.

H11 stillpending: no realSA3weights/import/inference/installation; knownbundlePython lacksmlx/sentencepiece, propose explicitisolatedtaskenvironment after rightsconfirmed. No legalterms acceptance/registration byLead. H12 exact1.5Bdownload command rejected byauto-review beforeexecution; no alternatepath/tool retry, no7B/32Bweightsdownload. H13 userconfirmedidle, all finalLeadCPU/CLI/GPU processes awaited; no newWorkeractive. OriginaloldFIFOchild exitunknown remains, not falselycleanedup. OriginalD/works untouched bytaskoperations; noGUI/signing/TCC/keys/globalCodexsettings changes.

Recovery: sourceinitialbeaaaf82d845e672c6a3b661d928654affc00518, onlyschemeunstaged sha ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c, indexblob9c76916bdc97c2d4298cefe64e0b0fae3380573e. Candidate codex/d-audio-backend-01 remains unacceptedforrealSA3; source may receive onlystatus/checklistdocs to preserve recoveryindex, never audio/UI/schema4default integration. Finalactualsource/candidate/push/protection in final-candidate-receipt.json; retainworktrees/branches/evidence, noreset/stash/rewrite/mainpush. Nextaction: userH11/H12 answers, verifycurrenthardware/taskstate then real6sSA3 generate/repeat/cancel-next/variation/inpaint with unchangedprecision+sourceprotection; largerMacmatrix later. Do not restartproductbatch or repeatedly retrydenieddownload.

## 2026-09-10 集中授权续办检查点

H09/H10/H11/H12均已明确获用户批准，不再等待原授权。H12固定1.5B权重10文件880,170,545bytes完整核验；实际统一CLI连续两次中文改写完成，每轮release active/cache=0，峰值966,847,960bytes。受测二进制来自d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407，候选03798abfe17229f7678f9fcd611df87da7c775ac仅后续文档；不是1.5B完整模型库GUI/取消/专业质量验收。

H11用户确认适用资格并授权固定small music四权重1,919,674,322bytes及独立依赖；下载完整核验，未代接受/注册。mlx/mlx-metal0.32.2、numpy2.3.5、sentencepiece0.2.2安装于新外盘venv，使用固定预编译wheel，原全局Python未变。首个6秒请求在计算前失败：当前Swift启动器解析python符号链接后运行基础解释器，丢失venv依赖。对照sys.prefix/find_spec确认；新建标准venv --copies保留明确真实可执行路径，CPU --inspect和完整固定权重/Vendor核对通过，未改实现/精度或注入PYTHONPATH。原环境/失败保留；此兼容限制不是SA3数值通过。

H09在独立HUM候选增加批准的用途说明和两个麦克风能力，并仅将DEBUG有效UUID+audio测试门传给recordingEnabled。Lead补正启用后仍显示“未启用”的旧侧栏文字；Sol/high受限只读复核先指出反例、后接受修正，未替代真实测试。候选372a8acadf39b92faf4b17b6315f0f63774e4cff普通既有身份签名构建成功；首版已核对Sandbox/Hardened Runtime及麦克风能力，修正版尚待重新启动/实际提示。没有替换普通D、变更Team/bundleID/钥匙串/TCC，schema4仍未源接纳。

H10用户最初已保存退出且空闲。首个自有测试PID37620创建本轮新项目后正常退出0；退出后CUA getAXState重新定位到“Model Library Acceptance”旧D窗口，尚不能确认其进程身份，未继续操作/关闭。已请用户保存退出该窗口；不能把它当本轮隔离实例。后续音频generate-copies启动被自动审批明确拒绝（仍有D运行、GPU空闲未重确认），命令未执行；没有换路径绕过。暂停GUI/GPU依赖项，独立CPU检查继续。不要再在Quit后调用D对象getAXState（工具可能重启/重定位）；用自有进程退出回执及仅枚举状态确认。

下一动作：收到退出/当前空闲证据后，重新以专属UUID启动已复核测试版，在真实“开始录音”入口交用户点击麦克风提示；完成短录音/试听与H10保存导出恢复。同时按单重任务顺序完成SA3生成/变体/重绘/取消与重复释放，以及1.5B剩余验证。许可和下载无需重复审批；当前资源拒绝不是全盘权限缺口。全部原预算/失败/来源保留，不启动新产品批次。

证据：H09 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T152120Z-h09-authorized`（preparation/label-fix、signed-build2、review/routing及两次review、app-run/result、protection-checkpoint）；H11 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T152406Z-h11-authorized`（authorization、download/environment/copies、environment-launch-diagnosis、generate失败、inspect-copies、retry-resource-rejection）；H12 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T151340Z-h12-authorized`（download-result、normal/report）。开发与用户媒体来源分开；本次Lead实施与实测，Sol只读审核；完整Lead/订阅消耗unknown。

## 2026-09-10 真实设备续验：局部通过，两个独立停点

最新用户“已退出且空闲”与启动前CUA全部D未运行核对后，恢复已批准串行验收。实际audio/text CLI仍为d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407；当前候选d63cd39仅后续记录，不把新文档当重新测试。

H11：固定SA3 small music6秒/8步/guidance1/seed42真实generate完成，首次进程6.82354秒；44100Hz双声道float32，264600帧，WAV SHA256 0aa169b29af568128b0c0f65e497b24f830a3699d77f363302dc3904f0f6a59b。MLX峰值1,611,041,742bytes；FP16 DiT/T5、FP32 codec/master未降精度。另一个实际repeat进程的两轮生成、variation和inpaint均完成，原始输入未变；重绘[88200,176400)范围内改变、外部PCM逐字节一致。独立两次同Python进程engine诊断清理后active18bytes/cache0，2轮未增长；18字节精确归属unknown，不写成0或常驻无泄漏保证。以上检查不是听感/专业质量验收。

取消验收未通过：观察CLI真实progress1/8发送TERM，CLI终态130，但进度在provider已经发布output.wav后才集中交付。保持合法产物与原失败，不把“130”单独算通过；后续after-cancel/timeout/after-timeout入口尚未执行。单管道CPU对照反驳“一切FileHandle.bytes都会缓冲”的早期猜测；双管道且stderr暂时无内容时，bytes首stdout1.230秒，POSIX读0.227秒（子进程约0.2秒写出，约1.23秒结束）。现象与真实失败一致；Foundation内部调度细节未取证。此轮仅诊断，无生产代码修补。

H12：既有两次真实中文改写之后，本轮同一Runtime两次生成1chunk后取消均完成，延迟0.03433/0.03685秒，每次release active/cache0，第二任务确在释放后启动。独立正常2次与取消2次分别记录，不混成同一测试通过率；1.5B模型库GUI、7/32B硬件/专业质量未验收。

H09/H10：修正版普通签名实例到达Start后被AudioTransport祖先路径检查拒绝，未请求麦克风/未录音。另一次实际GUI成功导入上述WAV、播放、保存精确Unicode注释和片段1..<264599、原件导出字节一致、片段导出PCM对应264598帧；随后正常退出0。重启实例时Mac锁定，GUI重开与真人听感仍待确认；精确核对自有PID40236后TERM退出-15，项目字节不变，没有关闭普通D。旧reservation保留，不猜测删除。

预算停点/待批准有界方案：Runtime原初交+两修复+一次Lead接管已消耗，本次真实双管道问题不是偷偷追加第三轮。建议仅AudioProviderProcess.swift及直接AudioBackendTests回归，改为各自及时且有界的管道读取，保留事件/解析/输出预算、完整drain、TERM/KILL和租约语义。增加silentstderr/分段stdout在退出前被消费的真实子进程反例，复验取消/下一任务/timeout/输出失败及既有CPU；真实SA3保持同配置复验。H09另在原HUM任务记录列出路径检查限定方案。两项均需明确额外收尾授权，不重置原预算；若有界修补后仍失败停报，重要实现由非实现者只读复核。不改精度/签名/权限/公共推理契约，不默认源集成。

证据：AUDIO run-20260909T152406Z-h11-authorized/live-acceptance-checkpoint.json，generate-copies、real-operations、memory-lifetime、cancel-handoff/cancel-denoising、progress-pipe-diagnosis和progress-two-pipe-diagnosis；H12 run-20260909T151340Z-h12-authorized/cancel/lead-verification.json；HUM run-20260909T152120Z-h09-authorized/h10-import-export-verification.json、recording-path-failure.json、review/path-response.md、path-routing.json、live-protection-checkpoint.json。本次Lead实测与诊断，无生产重写；Sol/high只读路径诊断433.486秒（不等于独立执行测试），完整Lead/订阅费用unknown，未重算历史用量。所有当前自有子进程结束；未宣称系统写锁。个人scheme未暂存且内容/索引、普通D四文件保持。最终文档提交/推送和恢复版本见本run live-final-receipt.json。

## 2026-09-10 源状态同步：仅文档冲突整合

源快照 9b20e0f20039027ce75b2bae00bffa215bc1789e 与音频候选 a0bfd0ec47ec40f93c7342934fc82dfd0ac754d0 保留历史合并。仅 CURRENT_ACTIONS/FAILURE_AND_PERMISSION_AUDIT 内容冲突；逐项对照后，全局入口保留源较新的 H09-H14 状态。候选特有的较早说明完整保存在下方作为历史，不作为本轮验收结论。产品、签名、权限和测试代码无冲突/无改动；未引入 HUM/schema4。

## 当前检查点：音频后端候选与跨配置验证（2026-09-10）

源产品基线 beaaaf82d845e672c6a3b661d928654affc00518；实现保留在 `codex/d-audio-backend-01`。**组合工程验证和既有图文实推通过，真实音频未验收，尚未把候选代码接入源分支或普通 D。** 后续源若有本批状态记录提交，仅为文档；完整最终SHA/推送状态见任务回执。

- 音频：AudioRequest → 统一任务/重推理许可 → 本地 Python SA3适配 → 44.1kHz双声道float32 WAV及冻结记录。generate/variation/inpaint、独立子进程停止/排空、文件校验与原件保护已实现；实际跨语言CLI三种操作CPU夹具通过。SA3真实权重/依赖未就绪，不能称已出声、听感通过或普通工作台可用。
- 跨配置：预算由主机内存政策计算；Qwen2.5 0.5/1.5/7/32B固定4-bit版本可分别登记校验；FLUX4Bq8显式尺寸profile贯穿张量到PNG，普通UI仍原512预设。1.5/7/32B与1024/2048实推待验证，不等于任意模型/Intel兼容。
- 完整组合受测 `d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407`：Python21方法、核心30方法通过；全UI包174方法报告，其中173执行通过/1既有可选权重项跳过；三个后端CPU套件42方法/100展开执行通过；CLI和无签名应用编译通过。三种真实跨语言CPU夹具通过。原27方法选择漏了一个类，已按实际类名完整重跑42，不相加为69。
- 实际模型：上述组合的既有0.5B文本10类和512²图像17类CLI回归完整通过；另768×512/4步/guidance1/seed42真图52.710秒，MLX峰值6,309,409,880bytes，释放active/cache均0，PNG可解码，Lead目视无明显方向/颜色异常。不是大模型、长时负载或音频推理证明。
- 阻塞：H11待用户确认SA3/Gemma条款/适用登记，随后才准备独立mlx/sentencepiece环境及固定音频权重；H12新1.5B下载被自动审批拒绝待明确答复。当前H13资源窗口已确认并完成串行图文回归。H09/H10保留旧音频UI候选的独立人工门槛。

四个实现工作包由Sol/high受限CLI完成，Lead审查/整合/实际验证；Python和运行时各耗用两轮普通修复，运行时另一次有界Lead修补并经非实现者只读审核接受。共享契约/清晰化错误与测试启动问题另记，不把最终结果全归为Worker独立通过。当前新实现/审核/验证进程已结束；最初超时旧FIFO测试子进程最终退出码unknown，原证据保留，未发现剩余已知源写入者，不能声称全系统写锁或完整进程审计。

保护：个人scheme完整摘要ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c保持未暂存、索引无夹带；没有打开/关闭/重签/改写普通D或操作既有作品。复用 [任务记录](tasks/D-AUDIO-BACKEND-01.md)、[调用/硬件指南](AUDIO_BACKEND_GUIDE.zh-CN.md)、外盘run-20260909T123045Z/final-candidate-receipt.json恢复。下一步仅完成音频真实生成/变体/重绘/取消释放与听感验收；通过后再接创作者候选比较/采用/保存。传统DAW、文字高级功能、全部META不是前置。

