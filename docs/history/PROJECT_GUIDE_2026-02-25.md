# PROJECT GUIDE: Unified MLX Inference Platform

<!--
  Version: 2.0.0
  Last Updated: 2026-02-25
  Maintainers: User, AI Assistants
  Purpose: Architecture overview, file mapping, concurrency rules, and collaboration guidelines.
  Note: Keep this file and `project_tree.txt` in sync with the codebase.
-->

## 1. Project Overview
- **Mission**: Build a robust, model‑file‑centric inference platform for generative AI on macOS using MLX Swift.
- **Core Philosophy**: Stability, maintainability, and extensibility over raw performance. Strict separation of UI (main thread) from business logic (actors, services) and pure data models (Sendable).
- **Target Audience**: Developers and AI assistants maintaining this codebase.

## 2. Architecture Principles
### 2.1 Layered Design (Strict Isolation)
```
[Presentation Layer] – SwiftUI Views (UI only, no logic)
          ↓
[ViewModel Layer]    – @MainActor classes (UI state, user event handlers)
          ↓
[Actor Layer]        – Concurrency‑safe state managers (ModelLoadingActor, InferenceCoordinatorActor)
          ↓
[Service Layer]      – Task‑oriented protocols (TextGenerationService, etc.)
          ↓
[Model Adapters]     – ModelAdapter implementations (e.g., LLaMAAdapter) using MLX
          ↓
[Hardware Layer]     – HardwareProfile, MLX configuration (pure data)
```

### 2.2 Concurrency Strategy
- **UI Thread**: Only `@MainActor` ViewModels and SwiftUI Views run on the main thread.
- **Data Models**: All value types (e.g., `ModelConfig`, `LoadedTensor`) are `Sendable` structs with `let` properties. No actor isolation annotations.
- **Protocols**: All protocol methods that may be called from background contexts are declared `nonisolated` (e.g., `ModelAdapter.loadWeights`).
- **Actors**: Shared mutable state is protected inside actors (`ModelLoadingActor`, `InferenceCoordinatorActor`). Actor methods are `nonisolated` to allow calling from any context; internal state is actor‑isolated.
- **MLXNN Subclasses**: Custom `Module` subclasses (e.g., `LLaMAAttention`) are marked `@unchecked Sendable`. All stored properties are `let` (or `nonisolated(unsafe) let`) and set during initialization, remaining read‑only thereafter.
- **AsyncStream**: Used to safely stream tokens across actor boundaries. Streams are created inside actors and consumed on the main actor (via `for await` in a `@MainActor` task).

## 3. Directory Structure and File Mapping
The exact file tree is maintained in **`project_tree.txt`** at the project root.
**Always update `project_tree.txt` after any file system change** (run `tree -L 3 > project_tree.txt` from the project root).

### 3.1 Top-Level Directories
| Directory | Purpose |
|-----------|---------|
| `Actors/` | Actor‑isolated state managers (thread‑safe business logic). |
| `Hardware/` | Hardware profiles and MLX configuration (pure data). |
| `ModelAdaptation/` | Core model‑handling code: protocols, adapters, tokenizers, utilities. |
| `Models/` | Pure `Sendable` data structures (no logic). |
| `Presentation/` | SwiftUI views (no business logic). |
| `Resources/` | Assets (images, icons). |
| `Services/` | Task‑oriented interfaces and their implementations (e.g., `TextGenerationService`). |
| `Tests/` | Unit and UI tests. |
| `Utils/` | Extensions, logging, helpers. |
| `ViewModels/` | `@MainActor` view models binding UI to logic. |

### 3.2 Key Files and Their Roles
| File | Role |
|------|------|
| `Models/ModelConfig.swift` | Pure struct representing `config.json`. All properties `let`. |
| `Models/LoadedTensor.swift` | Raw tensor data from safetensors. |
| `Models/GenerateParameters.swift` | Parameters for text generation. |
| `Models/InferenceTask.swift` | Enum describing a task (text, image, VL). |
| `Hardware/HardwareProfile.swift` | Snapshot of system memory/cores. |
| `Actors/ModelLoadingActor.swift` | Loads models, caches adapters, manages weight loading. |
| `Actors/InferenceCoordinatorActor.swift` | Manages memory budget, queues tasks, returns `AsyncStream<String>`. |
| `ModelAdaptation/Protocols/ModelAdapter.swift` | Core protocol for all model adapters. All methods `nonisolated`. |
| `ModelAdaptation/Common/SafetensorsLoader.swift` | Loads safetensors files into `[String: MLXArray]`. All methods `nonisolated static`. |
| `ModelAdaptation/Tokenization/BPETokenizer.swift` | BPE tokenizer (thread‑safe, `Sendable`). |
| `ModelAdaptation/TextModels/LLaMAAdapter.swift` | LLaMA‑family adapter. Internal classes are `@unchecked Sendable`. |
| `Services/TextGenerationService.swift` | Protocol for text generation. |
| `Services/LLaMATextGenerationService.swift` | Wraps `LLaMAAdapter` and conforms to `TextGenerationService`. |
| `ViewModels/MainViewModel.swift` | `@MainActor` class managing UI state and events. |
| `Presentation/MainView.swift` | Root SwiftUI view. |

### 3.3 File Size and Modularity
- Each Swift file should ideally be **≤500 lines**.
- If a file exceeds this, split by feature (e.g., `+Loading.swift`, `+Forward.swift`). Ensure splits are logical and maintain readability.

## 4. Concurrency Safety Guidelines
### 4.1 Data Models
- All data models (in `Models/`) must be `Sendable` structs with `let` properties.
- No `@MainActor`, `nonisolated`, or other actor annotations on these types – they are pure values.

### 4.2 Protocols
- Every protocol that will be used across actor boundaries must declare its methods as `nonisolated`.
- Example:
  ```swift
  protocol TextGenerationService: Sendable {
      nonisolated func generate(prompt: String, parameters: GenerateParameters) -> AsyncStream<String>
  }
  ```

### 4.3 Actors
- Actors should have **only one responsibility** (e.g., `ModelLoadingActor` loads and caches models).
- Public actor methods are `nonisolated`; they can be called from any context and internally `await` actor‑isolated operations.
- Private mutable state is actor‑isolated and accessed only within the actor.

### 4.4 MLXNN Subclasses
- All custom `Module` subclasses must be marked `@unchecked Sendable`.
- Store properties as `let` (or `nonisolated(unsafe) let`) and initialize them in `init`. After initialization, they become read‑only.
- Example:
  ```swift
  private class LLaMAAttention: Module, @unchecked Sendable {
      nonisolated(unsafe) let wq: Linear
      // ...
      nonisolated init(config: LLaMAConfiguration) {
          self.wq = Linear(...)
          super.init()
      }
  }
  ```

### 4.5 Cancellation
- All long‑running loops (e.g., token generation) must check `Task.isCancelled` at each iteration.
- When returning `AsyncStream`, set an `onTermination` handler to cancel the underlying task.

## 5. AI Collaboration Protocol
*(This section is identical to version 1.0.0; only minor adjustments if needed.)*

### 5.1 AI Capabilities
- Analyze code and project structure using provided files.
- Suggest code edits by outputting full revised file content.
- Propose new files with complete content and desired path.
- Request additional information (e.g., “Show me `File.swift`”).
- Ask for file system changes that cannot be performed directly.

### 5.2 What AI Cannot Do Directly
- Create, delete, or rename folders.
- Move files to different directories.
- Modify Xcode project files (`.pbxproj`) or build configurations.
- Run terminal commands or execute builds.
- Update `project_tree.txt` (user must run `tree` manually).

### 5.3 When File System Changes Are Needed
1. Clearly describe the operation (source → destination).
2. Explain the reason.
3. Wait for user to perform the change.
4. After user confirms and updates `project_tree.txt`, continue.

### 5.4 Communication Principles
- Always refer to the latest `project_tree.txt` for accurate paths.
- If a file exceeds 500 lines, suggest splits.

## 6. Dependencies
- MLX Swift (SPM)
- SwiftUI (built‑in)
- Combine (built‑in)
- (Add others as introduced)

## 7. Building and Testing
- Build: `⌘B` in Xcode.
- Run: `⌘R`.
- Unit tests: `⌘U` (tests should reside in `Tests/UnitTests`).
- Enable Thread Sanitizer: Edit Scheme → Diagnostics → Thread Sanitizer.

## 8. Version History
| Date | Version | Changes |
|------|---------|---------|
| 2026-02-24 | 1.0.0 | Initial guide after file restructuring. |
| 2026-02-25 | 2.0.0 | Complete rewrite to reflect strict layered architecture, concurrency rules, and removal of CPU stubs. Added guidelines for MLXNN subclasses and `@unchecked Sendable`. |

## 9. Known Issues & TODOs
- [ ] Implement `SafetensorsLoader` with full `MLXArray` conversion.
- [ ] Complete `LLaMAAdapter`:
  - [ ] Define internal classes with `@unchecked Sendable`.
  - [ ] Implement `loadWeights` using `update(parameters:)`.
  - [ ] Implement streaming generation with KV cache and cancellation.
- [ ] Create `LLaMATextGenerationService` to wrap adapter.
- [ ] Update `ModelAdapterFactory` to register LLaMA.
- [ ] Write unit tests for core components (SafetensorsLoader, tokenizer).
- [ ] Integrate a small test model (e.g., TinyLlama) to validate end‑to‑end flow.