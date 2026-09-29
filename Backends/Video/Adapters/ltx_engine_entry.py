"""Pinned LTX CLI entry with an explicit, non-fallback temporary directory."""
import os
from pathlib import Path
import stat
import tempfile


def fix_temporary_directory():
    path = Path(os.environ['TMPDIR'])
    if not path.is_absolute() or not stat.S_ISDIR(path.lstat().st_mode):
        raise ValueError('LTX requires an explicit physical task temporary directory')
    # Unlike TMPDIR discovery, tempfile.tempdir does not fall back to system paths.
    tempfile.tempdir = str(path)


if __name__ == '__main__':
    fix_temporary_directory()
    from ltx_pipelines_mlx.cli import main
    raise SystemExit(main())
