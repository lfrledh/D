# D-ALIGN-TEXT-01 / implementation-r1 / ALIGN1

Status: issued for PRECHECK, implementation only after Lead routing acceptance. Batch D-ALIGN-01. Source base aa277f965629591a23f80f7f4baf3b081cd8de2a; execution base is exact preparation commit reported in launch metadata (contains this record). run_id run-20260913T104905Z-text. Model gpt-5.6-sol / high.

Read AGENTS current safety, docs/tasks/D-ALIGN-01.md section `2026-09-13 实施记录` and files necessary below, not all history.

## Goal and immutable acceptance
Implement text capability and per-request budget resolution, TextGenerationSettings and existing text draft/controller wiring only. Exact frozen API in stage ALIGN1 section. Preserve old explicit maxTokens caller behavior; new controller submits settings. Use optional maxTokens parameter if needed to distinguish omission from explicit legacy override, don't silently ignore explicit caller maxTokens. Text settings change revision and stale existing candidates without modifying original text. Preserve settings on every edit/accept/undo construction. Archive2 reads v1 and v2, validates integer versions as before, no target bytecode. Unknown profile is decodable/history-visible but request rejected. Add focused tests for capability bounds/unknowns, legacy JSON, settings roundtrip/edit/accept/undo, in-flight stale (incl A-B-A), selected request snapshot. Do not change ProjectStore; tell Lead necessary integration. Backend configuration resolves local immutable limits, inspect and true tokenizer/execution use same chosen budget. KV overflow/model total context checks unchanged. Add actual profile and max input/output metadata. No token char counting/truncation, lifecycle changes or model precision changes.

## Exact allowed paths
- Sources/DInference/TextExecutionCapability.swift
- Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift
- Backends/MLX/Sources/DMLXBackend/MLXDiagnostics.swift
- Backends/MLX/Sources/DMLXBackend/LocalModelInventory.swift
- Backends/MLX/Tests/DMLXBackendTests/TextExecutionCapabilityTests.swift
- Packages/UI/Sources/DWorkbench/Text/TextGenerationSettings.swift
- Packages/UI/Sources/DWorkbench/Text/TextDraft.swift
- Packages/UI/Sources/DWorkbench/Text/TextDraftSession.swift
- Packages/UI/Sources/DWorkbench/Text/TextDraftArchive.swift
- Packages/UI/Sources/DWorkbench/Text/ProjectTextController.swift
- Packages/UI/Tests/DWorkbenchTests/TextExecutionSettingsTests.swift
- Tests/DRuntimeTests/TextExecutionCapabilityTests.swift

No other file edits, including this task record. No shared InferenceRequest/ExecutionProfileReference, ProjectSession/Store/Models, UI, App/CLI, runtime, dependencies, Vendor, signing/settings. Local helper code/logs only under /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/text/output or /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/text/tmp. No commit/common Git writes. No delegation. Stop and report any new requirement.

## Execution and evidence
Worktree /Volumes/CodexProjects/Codex/D-Worktrees/D-ALIGN-TEXT-01. Git explicit /Applications/Xcode.app/Contents/Developer/usr/bin/git. Sandbox workspace-write implicit task root + only /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/text/output and /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/text/tmp; network false. TMPDIR/D_TEST_TEMP_DIR/Python cache already fixed there. Precheck no edits/tests. After IMPLEMENT: read and edit authorized files; lightweight Swift syntax via explicit /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -parse [owned files] only (does not prove type checking). No SwiftPM/xcrun/full build/GPU/GUI/MLX runtime/model load/network/download/config/keys. Lead runs types/full CPU suites independently. Python syntax if needed tokenize.open + compile in memory (no exec/import target). Unknown permission refusal/runtime warning: pause that action and report; do not find bypass. Only predeclared fallback is own tmp or no-bytecode check for cache; actual successful escape/identity/source protection failure stops task.

Initial implementation max900s plus at most two targeted fixes; no task/model renaming to refresh. Return exact changed paths, behavior/test evidence, remaining uncertainty, process state, implementation choices/Lead help. Output report under own output or final message; don't edit frozen record. Worker handback needed before Lead writes/commits this tree.
