# D-ALIGN-AUDIO-01 / implementation-r1 / ALIGN1

Status: issued for PRECHECK, implementation only after Lead routing acceptance. Batch D-ALIGN-01. Source base aa277f965629591a23f80f7f4baf3b081cd8de2a; execution base is exact preparation commit reported in launch metadata (contains this record). run_id run-20260913T104905Z-audio. Model gpt-5.6-terra / medium.

Read AGENTS current safety, docs/tasks/D-ALIGN-01.md section `2026-09-13 实施记录` and files necessary below, not all history.

## Goal and immutable acceptance
Only expose accurate small typed capability descriptions. AudioExecutionCapability frozen fields in stage spec; operations use [AudioOperation] if Set needs unprovided Hashable, do not modify shared AudioRequest. Also include engineContract value (actual existing AudioEngineContract name/type inspect), note frame/max note limits when applicable optional (unknown vs not-applicable documented); profile is ExecutionProfileReference. Generate separate contract descriptors as needed for operation distinction but no generic plugin factory. MLXAudioBackend.executionCapability derived from actual configuration.profile (sm-music, sm-sfx, medium have distinct existing max durations). MRT2 descriptor reflects small fixed actual duration/notes/sample rate/seed and no edit/variation it doesn't implement. Inspect actual provider validation: do not infer capabilities from enum names or standard model advertising. Approximate notes/reference obedience, no exact semantic promises. New public properties immutable nonisolated. Do not change actual provider protocol, lifecycle, inference or registry and do not declare instances automatically deployed. Focused pure contract/backend configuration tests; no real engine or media/model I/O. Lead injects only actual instantiated descriptors into workbench. For declarations that require unresolved semantics report ambiguity before coding; refuse invented support.

## Exact allowed paths
- Sources/DInference/AudioExecutionCapability.swift
- Backends/MLX/Sources/DMLXBackend/AudioExecutionCapabilities.swift
- Backends/MLX/Sources/DMLXBackend/MLXAudioBackend.swift
- Backends/MLX/Sources/DMLXBackend/MLXMRT2Backend.swift
- Backends/MLX/Tests/DMLXBackendTests/AudioExecutionCapabilityTests.swift
- Tests/DRuntimeTests/AudioCapabilityContractTests.swift

No other file edits, including this task record. No shared InferenceRequest/ExecutionProfileReference, ProjectSession/Store/Models, UI, App/CLI, runtime, dependencies, Vendor, signing/settings. Local helper code/logs only under /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/audio/output or /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/audio/tmp. No commit/common Git writes. No delegation. Stop and report any new requirement.

## Execution and evidence
Worktree /Volumes/CodexProjects/Codex/D-Worktrees/D-ALIGN-AUDIO-01. Git explicit /Applications/Xcode.app/Contents/Developer/usr/bin/git. Sandbox workspace-write implicit task root + only /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/audio/output and /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z/audio/tmp; network false. TMPDIR/D_TEST_TEMP_DIR/Python cache already fixed there. Precheck no edits/tests. After IMPLEMENT: read and edit authorized files; lightweight Swift syntax via explicit /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -parse [owned files] only (does not prove type checking). No SwiftPM/xcrun/full build/GPU/GUI/MLX runtime/model load/network/download/config/keys. Lead runs types/full CPU suites independently. Python syntax if needed tokenize.open + compile in memory (no exec/import target). Unknown permission refusal/runtime warning: pause that action and report; do not find bypass. Only predeclared fallback is own tmp or no-bytecode check for cache; actual successful escape/identity/source protection failure stops task.

Initial implementation max900s plus at most two targeted fixes; no task/model renaming to refresh. Return exact changed paths, behavior/test evidence, remaining uncertainty, process state, implementation choices/Lead help. Output report under own output or final message; don't edit frozen record. Worker handback needed before Lead writes/commits this tree.
