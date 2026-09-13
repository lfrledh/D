# D-ALIGN-IMAGE-01 / implementation-r1 / ALIGN1

Status: issued for PRECHECK, implementation only after Lead routing acceptance. Batch D-ALIGN-01. Source base aa277f965629591a23f80f7f4baf3b081cd8de2a; execution base is exact preparation commit reported in launch metadata (contains this record). run_id run-20260913T104905Z-image. Model gpt-5.6-sol / high.

Read AGENTS current safety, docs/tasks/D-ALIGN-01.md section `2026-09-13 实施记录` and files necessary below, not all history.

## Goal and immutable acceptance
Implement typed image capability as single source of existing envelope and estimate, preserve ImageExecutionProfile public API as wrapper/forwarder for existing tests/CLI. New image request executionProfile is optional: nil uses immutable host; explicit known profile resolved within host envelope; default verified512 host must reject scalable identifier even requesting512. Scalable host may accept verified512 and scalable request; strict resolved profile validates request and determines actual metadata. Resolve once per invocation or pure consistent functions; no current-profile actor mutable state. Keep 4Bq8, steps4/guidance1/text512, estimate exact old formula, width range256...2048 stride32. Do not touch memory cleanup/pipeline numeric code except passing actual resolved profile. Add ImageGenerationSettings as frozen stage API (explicit public init, legacy512 default); unknown decoded profile preserved but validation fails. Reference constants single source; wrapper can't diverge. Tests legacy request/nil and explicit requests, unknown versions, host mismatch, dimensions overflow/bounds, estimate equality, metadata construction relevant unit evidence. No ProjectSession/ModelLibraryTypes modifications; send Lead integration notes.

## Exact allowed paths
- Sources/DInference/ImageExecutionCapability.swift
- Backends/MLX/Sources/DMLXBackend/ImageExecutionProfile.swift
- Backends/MLX/Sources/DMLXBackend/LocalImageModelInventory.swift
- Backends/MLX/Sources/DMLXBackend/MLXImageBackend.swift
- Backends/MLX/Tests/DMLXBackendTests/ImageExecutionSelectionTests.swift
- Packages/UI/Sources/DWorkbench/Models/ImageGenerationSettings.swift
- Packages/UI/Tests/DWorkbenchTests/ImageGenerationSettingsTests.swift
- Tests/DRuntimeTests/ImageExecutionCapabilityTests.swift

No other file edits, including this task record. No shared InferenceRequest/ExecutionProfileReference, ProjectSession/Store/Models, UI, App/CLI, runtime, dependencies, Vendor, signing/settings. Local helper code/logs only under /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/image/output or /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/image/tmp. No commit/common Git writes. No delegation. Stop and report any new requirement.

## Execution and evidence
Worktree /Volumes/CodexProjects/Codex/D-Worktrees/D-ALIGN-IMAGE-01. Git explicit /Applications/Xcode.app/Contents/Developer/usr/bin/git. Sandbox workspace-write implicit task root + only /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/image/output and /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/image/tmp; network false. TMPDIR/D_TEST_TEMP_DIR/Python cache already fixed there. Precheck no edits/tests. After IMPLEMENT: read and edit authorized files; lightweight Swift syntax via explicit /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -parse [owned files] only (does not prove type checking). No SwiftPM/xcrun/full build/GPU/GUI/MLX runtime/model load/network/download/config/keys. Lead runs types/full CPU suites independently. Python syntax if needed tokenize.open + compile in memory (no exec/import target). Unknown permission refusal/runtime warning: pause that action and report; do not find bypass. Only predeclared fallback is own tmp or no-bytecode check for cache; actual successful escape/identity/source protection failure stops task.

Initial implementation max900s plus at most two targeted fixes; no task/model renaming to refresh. Return exact changed paths, behavior/test evidence, remaining uncertainty, process state, implementation choices/Lead help. Output report under own output or final message; don't edit frozen record. Worker handback needed before Lead writes/commits this tree.
