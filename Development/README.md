# Local development resources

Debug uses `Development.local.xcconfig` (ignored) to locate the verified local engine resource set and the already approved development signing identity. Prepare once using `scripts/prepare-development-resources.py`, then set `D_DEVELOPMENT_RESOURCES` to that absolute output directory. Set `D_DEVELOPMENT_SIGNING_IDENTITY` and `D_DEVELOPMENT_TEAM` only to your existing development identity. Do not put credentials in this file.

The normal D build embeds engines before the ordinary Xcode signing step. The resource set contains runtime code and, for the current internal Pitch engine, the explicitly tracked evaluation weight; it does not contain Qwen/FLUX/MRT2/Wan weights. This is a development configuration, not a distribution artifact. Missing or changed resource inputs fail with a preparation message rather than producing an app that appears ready.

No dependencies are downloaded or installed during a build. Updated resource sets require a fresh task-owned DerivedData directory if the existing engine inventory differs; unknown build contents are not silently overwritten.
