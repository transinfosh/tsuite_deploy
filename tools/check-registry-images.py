#!/usr/bin/env python3
"""Check resolved Compose images before changing a deployment (no containers are started)."""

import argparse
import os
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "images", nargs="*", help="Full image references, or one per line on stdin"
    )
    parser.add_argument("--registry", default="registry.trinfo.net")
    args = parser.parse_args()
    images = sorted(set(args.images or sys.stdin.read().split()))
    if not images:
        parser.error(
            "No images supplied; pipe docker compose config --images into this command"
        )
    env = os.environ.copy()
    bypass = ",".join(
        filter(None, (env.get("NO_PROXY"), env.get("no_proxy"), args.registry))
    )
    env.update(NO_PROXY=bypass, no_proxy=bypass)
    failures = 0
    for image in images:
        if not image.startswith(args.registry + "/") or (
            ":" not in image.rsplit("/", 1)[-1]
        ):
            print(
                f"FAIL {image}: use an explicit version or digest in {args.registry}",
                file=sys.stderr,
            )
            failures += 1
            continue
        result = subprocess.run(
            ["docker", "manifest", "inspect", image],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            print(
                f"FAIL {image}: unavailable; check read-only login and mirror this exact version",
                file=sys.stderr,
            )
            failures += 1
        else:
            print(f"OK {image}")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
