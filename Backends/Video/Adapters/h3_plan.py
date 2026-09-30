"""Value-only plan for the pinned H3 FL2VA CLI; this does not run the model.

Local path checks do not verify checkpoint completeness, BF16 precision, engine
identity, output reservation, or readiness for execution. Those belong to the
caller before launching a process.
"""

import os
import stat


PROFILE = "minimax-h3-fl2va-bf16-full-v1"
UPSTREAM_REVISION = "8974cc055ea9c02fcd14cc27dfda3e1027c05153"
_FIELDS = frozenset({
    "schema_version", "profile", "prompt", "negative_prompt", "width",
    "height", "frames", "fps", "steps", "seed", "stream_weights",
})


def _integer(request, key, minimum, maximum):
    value = request[key]
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{key} must be an integer in [{minimum}, {maximum}]")
    return value


def _local_path(value, name, kind):
    if type(value) is not str or not value or "\0" in value or not os.path.isabs(value):
        raise ValueError(f"{name} must be a nonempty absolute local path")
    try:
        mode = os.stat(value).st_mode
    except OSError as error:
        raise ValueError(f"{name} is not an accessible local {kind}") from error
    if kind == "file" and not stat.S_ISREG(mode):
        raise ValueError(f"{name} must be a regular file")
    if kind == "directory" and not stat.S_ISDIR(mode):
        raise ValueError(f"{name} must be a directory")
    return value


def _output_path(value):
    if type(value) is not str or not value or "\0" in value or not os.path.isabs(value):
        raise ValueError("output must be a nonempty absolute local path")
    # lexists catches dangling symlinks, which exists deliberately misses.
    if os.path.lexists(value):
        raise ValueError("output already exists")
    parent = os.path.dirname(value)
    _local_path(parent, "output parent", "directory")
    return value


def build_plan(request, *, engine, model, output, text_encoder=None,
               first_frame=None, last_frame=None):
    """Return argv, environment overrides, and provenance without side effects.

    `environment` contains the required override, not a copy of the host's
    environment. The executor must control the complete launch environment.
    """
    if type(request) is not dict or set(request) != _FIELDS:
        raise ValueError("request must have exactly the H3 v1 fields")
    _integer(request, "schema_version", 1, 1)
    if type(request["profile"]) is not str or request["profile"] != PROFILE:
        raise ValueError("unsupported H3 profile")
    prompt = request["prompt"]
    negative_prompt = request["negative_prompt"]
    if type(prompt) is not str or not prompt.strip() or "\0" in prompt:
        raise ValueError("prompt must be a nonempty string")
    if type(negative_prompt) is not str or negative_prompt != "":
        raise ValueError("H3 FL2VA does not support negative_prompt")
    width = _integer(request, "width", 32, 768 * 1344)
    height = _integer(request, "height", 32, 768 * 1344)
    if width % 32 or height % 32 or width * height > 768 * 1344:
        raise ValueError("H3 canvas requires multiples of 32 within 768*1344 pixels")
    frames = _integer(request, "frames", 22, 362)
    if (frames - 5) % 17:
        raise ValueError("H3 FL2VA requires 17n+5 frames")
    _integer(request, "fps", 24, 24)
    steps = _integer(request, "steps", 2, 1000)
    seed = _integer(request, "seed", 0, 2**64 - 1)
    stream = request["stream_weights"]
    if type(stream) is not bool:
        raise ValueError("stream_weights must be boolean")
    if text_encoder is not None:
        raise ValueError("H3 does not accept a separate text_encoder path")

    engine = _local_path(engine, "engine", "file")
    if not os.access(engine, os.X_OK):
        raise ValueError("engine must be executable")
    model = _local_path(model, "model", "directory")
    output = _output_path(output)
    if first_frame is not None:
        first_frame = _local_path(first_frame, "first frame", "file")
    if last_frame is not None:
        last_frame = _local_path(last_frame, "last frame", "file")

    # Use --name=value so even a prompt beginning with '-' is an option value.
    argv = [
        engine, f"--model-dir={model}", f"--prompt={prompt}",
        f"--output={output}", f"--width={width}", f"--height={height}",
        f"--frames={frames}", f"--steps={steps}", f"--seed={seed}",
        "--layers=50", "--reuse=1", "--core-reuse=1",
        "--use-reference-rope", "--use-slower-bf16-mlp",
        "--use-slower-bf16-qkv", "--use-slower-bf16-attention-output",
    ]
    if first_frame is not None:
        argv.append(f"--first-frame={first_frame}")
    if last_frame is not None:
        argv.append(f"--last-frame={last_frame}")
    if stream:
        argv.append("--ssd-streaming")
    environment = {"H3_DIT_F32_FINAL": "1"}
    provenance = {
        "schema_version": 1,
        "profile": PROFILE,
        "expected_engine_source": f"antirez/h3.c@{UPSTREAM_REVISION}",
        "engine": engine,
        "model": model,
        "output": output,
        "request": request.copy(),
        "frame_conditions": {"first_frame": first_frame, "last_frame": last_frame,
                             "first_transform": "STRETCH" if first_frame else None,
                             "last_transform": "COVER" if last_frame else None},
        "weight_loading": "ssd-streaming" if stream else "resident",
        "resource_and_precision_verified": False,
        "execution_performed": False,
    }
    return {"argv": argv, "environment": environment, "provenance": provenance}
