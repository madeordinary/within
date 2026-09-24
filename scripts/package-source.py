#!/usr/bin/env python3
"""Package validated Git-index objects, never arbitrary working-tree contents."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import zipfile

from publication_policy import PolicyError, index_entries, repository_root, validated_blobs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/Within-source.zip"))
    args = parser.parse_args()
    try:
        root = repository_root()
        blobs = validated_blobs(root, index_entries(root))
        output = args.output.absolute()
        # Avoid overwriting any source file, including an allowed public path.
        if any(output.resolve() == (root / entry.path).resolve() for entry, _ in blobs):
            raise PolicyError("Archive output must not overwrite a tracked file.")
        output.parent.mkdir(parents=True, exist_ok=True)
        # Refuse existing destinations, including symlinks and older archives.
        with output.open("xb") as stream:
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for entry, data in sorted(blobs, key=lambda item: item[0].path):
                    info = zipfile.ZipInfo(f"Within-source/{entry.path}", (1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = int(entry.mode, 8) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, data)
        print(f"Packaged {len(blobs)} reviewed Git-index files.")
    except (PolicyError, OSError) as error:
        # OSError text can contain a personal output path.
        message = str(error) if isinstance(error, PolicyError) else "Cannot create archive; choose a new writable destination."
        print(f"Source archive refused: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
