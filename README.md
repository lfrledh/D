# D — Local AI Workbench for Mac

[简体中文](README.zh-CN.md) · **Development Preview**

D is a native multimodal AI workbench for Apple Silicon Macs. Use **Quick** for a single model, or assemble editable operations on the **workflow canvas**. Both surfaces share model capabilities, runtime scheduling and project assets. Inspect inputs, keep candidates separate from accepted work, and decide what runs next.

The node workbench is implemented. This repository is an active development baseline, **not a production release**. Successful model runs, native interaction checks, feature freeze and distribution readiness are tracked separately. There is no public installer yet.

## What is implemented

| Area | Current scope |
| --- | --- |
| Quick and workflows | Model selection, typed operations, editable connections and parameters, optional human decisions, candidates, project save/reopen and export. Some native interactions still need acceptance. |
| Text / vision | Qwen3.5-9B and Qwen3.8-27B: text, ordered images, sampled video frames and structured tool messages. D does not automatically execute returned tool calls. |
| Images | FLUX.2-klein-4B and FLUX.2-dev: text generation and ordered reference images. Original precision and separately identified quantized profiles are not interchangeable. |
| Video | Wan2.1-T2V-1.3B (text to silent video); LTX-2.5 dev single-stage (text / first frame to audiovisual video); MiniMax H3 Base FL2VA (text / first and last frame to audiovisual video). This is not every mode of each model family. |
| Music | MRT2 small/export-v1 with actual note/chord conditions; ACE-Step 1.5 XL SFT F32/no-LM generation, lyrics/reference, cover and repaint. Music control is approximate, not guaranteed score fidelity. |
| Resources | Explicit model download/import, preparation and validation, shared installation leases, cancellation and asset provenance. Explicit external references or independent copies, known-location inspection/recovery, project media collection and manual backup/independent restore are implemented. File services and connected component tests pass; native file-panel acceptance remains pending. |

The [model capability matrix](docs/RELEASE_MODEL_MATRIX.zh-CN.md) records exact profiles, revisions and tested modes. Full representative original-precision requests have run using SSD layering for Dev, H3 and LTX, with cancellation and real artifact storage checks. This does not establish every parameter combination, large-memory resident mode or current App interaction.

## Requirements and development build

- Apple Silicon Mac; the App deployment target is **macOS 26.2**. Current local validation uses Xcode 27.0 on macOS 26.6.2. Other configurations need their own verification.
- Sufficient disk space for fixed dependencies, engine resources and user-selected models. A 16 GiB development machine is **not** a product capability ceiling. Original-precision SSD loading can take hours; it changes residency, not model precision or layer count.
- Xcode and the pinned Swift package dependencies; the first dependency resolution can require network access.
- Prepared local engine bundles and your own development signing identity. A clean clone alone is **not** a complete runnable App environment.

```sh
git clone https://github.com/lfrledh/D.git
cd D
```

Prepare the verified engine resource set with the existing tool. The output parent directory must exist; use a new output directory:

```sh
python3 scripts/prepare-development-resources.py \
  --config /absolute/path/prepared-inputs.json \
  --output /absolute/path/prepared-resources
```

The JSON has `schemaVersion: 1` and an `engines` map from bundle name to an existing absolute path. The four baseline bundles are `AudioEngine.dengine`, `MRT2MusicEngine.dengine`, `VideoEngine.dengine` and `PitchEngine.dengine`; the current H3/LTX and ACE capabilities additionally require `ExternalVideoEngine.dengine` and `ACEMusicEngine.dengine`. This tool verifies and packages **already prepared** engines; it is not a dependency or model installer. See [development resources](Development/README.md) and [backend/source navigation](docs/REPOSITORY_MAP.zh-CN.md) for preparation entry points and fixed-source responsibilities.

Create the ignored `Development/Development.local.xcconfig`:

```xcconfig
D_DEVELOPMENT_RESOURCES = /absolute/path/prepared-resources
D_DEVELOPMENT_SIGNING_IDENTITY = Apple Development: YOUR EXISTING IDENTITY
D_DEVELOPMENT_TEAM = YOUR TEAM ID
```

Open **D.xcworkspace**, choose **D / My Mac / Debug**, and Run. **D Nodes** uses the same target with an isolated, persistent trial identity. The ordinary build embeds verified engines and signs the App; do not patch providers into an already built App.

For a command-line build with separate outputs:

```sh
D_DEVELOPMENT_ROOT=/absolute/path/build-output ./scripts/build-local.sh
```

Add `--offline` only when the required dependencies are already cached. It does not impose system-wide network isolation. Engine/model acquisition is separate from Swift compilation; no claim is made that the older `build-development-app.py` prepares the complete six-engine set automatically.

## Known limitations and next work

- IME candidate positioning and mouse-cursor reversion remain under targeted diagnosis. Input selection has passed previous human checks; that does not close positioning defects.
- Current App acceptance is incomplete. Two offscreen hosting tests did not reach their intended controls; their failures remain recorded.
- The LTX synthetic first-frame sample retains a planar red region. Its cause and general control quality are not settled. Short H3 samples do not establish long-video quality.
- A known UI recovery gap remains: a missing Quick asset can fail preview before its location inspector opens when a separate named Canvas project is active. Known-use navigation and verification-time presentation also remain incomplete.
- The new file-management panels are compiled but await native acceptance. Default browsing checks metadata rather than rehashing media; an explicit content check does read the file. Backups exclude models by default, restore to a new project instance, and do not include device authorization. Real NAS behavior remains untested; there is no cloud synchronization or concurrent multi-Mac library writing.
- Clean-machine setup, dependency packaging, upgrades/recovery and distribution checks remain. The intended distributed App does not bundle model weights; the current internal Pitch development engine still includes an evaluation ONNX weight and is **not** a distribution package.

Models are acquired explicitly by the user; their terms and sources are separate from D's code. No new model family, training system, remote service or mobile client is part of the current closeout.

## Development, feedback and licensing

Start with [current status](docs/CURRENT_ACTIONS.zh-CN.md), [repository map](docs/REPOSITORY_MAP.zh-CN.md) and the single [risk-based testing policy](docs/TESTING_POLICY.zh-CN.md). Most engineering records are currently in Chinese. Pure contract/runtime tests use `scripts/test-foundation.sh`; workbench CPU checks use `scripts/test-workbench.sh`. Select the affected tests rather than regenerating every model output. Model tests need the specified local resources and a free compute slot.

Report reproducible problems through [GitHub Issues](https://github.com/lfrledh/D/issues), including the commit, macOS/chip/memory, model profile and concise steps. Remove private prompts, project files and credentials before sharing logs.

**No repository-wide open-source license has been granted in this repository.** Public source visibility is not a grant of MIT/Apache or unrestricted reuse. Third-party source retains its own notices; see [Vendor provenance](Vendor/README.md) and the LICENSE/NOTICE files in the respective backend/dependency directories. This update does not change licensing or announce a commercial release.
