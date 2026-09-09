# D-AUDIO-BACKEND-01 — 音频推理与跨配置扩展

状态：准备中，2026-09-09。用户授权本阶段实施、测试、集成与 GitHub 工作分支推送。源基线 beaaaf82d845e672c6a3b661d928654affc00518；本文件后续记录完整执行版本。

目标：模型驱动的音频生成／参考变体／区间重绘后端；将本机测试规格与产品可扩展模型/资源政策分离。优先小模型本机真实验收，大配置必须标明适配与待实测，不更改既有 FLUX q8、Qwen 4-bit 精度。音频具体模型及精度在核实官方代码/许可后冻结，不把研究资料当本机实测。

本批不做传统 DAW、乐谱排版、歌声模型全家桶、手机、录音权限、签名或旧音频 schema4 默认接纳。H09/H10 与后端文件输入独立。录音/用户 D/现有作品/源 scheme/旧证据保持。没有安全资源窗口时真实 GPU 项记缺口，不能冒充通过或启用未验收产品路径。

协作：Lead 管契约和集成；每任务初交+最多两轮针对性修复，之后可一次有界 Lead 接管；重要 Lead 实现需非实现者审核。至多两名活跃子执行/审核；独立受限 CLI 工作树，网络关闭，共享 Git 由 Lead 管。当前只读模型选择核验与资源 Worker 预检可并行。

证据：D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T123045Z。保护/源快照见 preparation.json。进程枚举被当前沙箱拒绝，旧任务终止依据已有回执；未声称全系统空闲或写锁。

下一动作：SCALE 预检→实现，Lead 冻结音频模型与数据契约，再派后端。所有未验收项与实际限制留在本记录。

## Shared audio value contract (Lead, AUDIO1)
AudioRequest/AudioSourceReference/AudioEditRegion add a value-only audioGeneration input. Source-frame half-open coordinates, immutable hash/metadata and operation-dependent validation; backend must still validate actual media/model limits. Existing tasks view exhaustiveness is updated only to return prompt, not enable audio submission or project schema4. This code needs core/combined tests and nonimplementer review.

## Lead checkpoint 2026-09-09 (in progress)
SCALE Sol/high first delivery831.582s, eight allowed files; Lead read changes and core23 tests passed. Candidate3f18d6ce0377dc90fedeef037be136ccbcc121a7, metadata22 tests first failed due Lead test launch not forwarding D_TEST_TEMP_DIR (default/var symlink); configured xctestrun reuse passed original22 methods, zero skips/failures. Evidence scale-mlx-cpu-first, scale-mlx-cpu-configured, scale-core-first. No GPU or ordinary D launch. Isolated batch mergef40cfd8 includes candidate, not source acceptance.
AudioAUDIO1 values were Lead code atd528fc0d; priorcore17 passed (no new audio behaviors yet). Python task precheck identified protocol ambiguity; Lead spec2 specified fields but miscounted4weights as5. First implementation531.267s paused without retained code; Worker also inspected wrong research-archive provenance rather than shipped Vendor manifest. Spec3 corrects4weights and explicit vendoredroot/SHA; prior attempt retained, no accepted implementation/ordinary repair consumed. Runtime precheck correctly identified4/5 mismatch; spec2 corrects beforeimplementation. Both same Sol/high/no-network/externalwrite roots independently observed. Current workers may be active; inspect process receipts, do not edit their files concurrently.
Pinned SA3 code779434a908193105335fd8d833418603625b2859 MIT subset, optimized modelda6edc54ddba10bfd79a077102ded687f80e882b manifests fourfiles each: smallmusic/SFX1,919,674,322bytes, medium6,883,369,494bytes. These are download totals, not RAM. Weights notdownloaded. H11 license pending (https://huggingface.co/stabilityai/stable-audio-3-optimized/blob/main/LICENSE.md and https://ai.google.dev/gemma/terms). Python3.12.14 arm64 bundledruntime exists, numpy2.3.5 present; mlx/sentencepiece notinstalled, no installation performed. Readonly metadata is not inference.
Qwen1.5/7/32B pinned manifests/config4bit/group64/apache2 metadata prepared at eaaab0d8bf4b2da3f9f081757b1293933bfbbcfb; actual files/identities in text-catalog-research. Attempt to download1.5B was rejected by automatic approval review citing old no-download authorization; command entirely unexecuted, no alternate attempt. H12 asks explicit scope. H13 resourcewindow unknown; no process/IORegistry escalation, vm_stat not GPU ownership proof.
Lead prep helper initialUTF8 direct parser reported SyntaxError twice despite same bytes tokenization/compile success; ASCII escaped equivalent ran. Rootcauseunknown, no code ran on parsefailure, no permissionschanged. No source/path fallback. This is a Lead environmentevent, not Worker failure. No historical usage recalculation; eachrun rawincrementalusage retained, serverhiddenresolution/completeLead/subscriptioncost unknown.
Resume: sourceHEADbeaaaf82d845e672c6a3b661d928654affc00518, schemeSHAca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c onlyunstaged, sourceindexclean. Active Python/runtime CLI ownedrunfiles; SCALEended. Textprofiles worker still not launched, firstdelivery/repairsnotconsumed. Next: finish CPU adapters/registration, review and combine exact SHAs, license/download/GPU gates independent. No sourceff/pushyet; do not call stagecomplete.
