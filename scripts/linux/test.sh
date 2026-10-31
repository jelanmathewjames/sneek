#!/usr/bin/env bash
# Build sneekd and run SneekTests inside the pinned Linux Swift toolchain.
# Uses a named volume for .build so Linux artefacts never mix with the Mac's .build/.
set -euo pipefail
IMAGE="swift@sha256:7060a792f4cd9eaa0d00826d941cec00ab8d252d33b8b28bc8e105f51f2dba73"   # swift:6.3-bookworm (Swift 6.3.3, same as the Mac toolchain)
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RUNS="${RUNS:-1}"
docker run --rm -v "$REPO":/src:ro -v sneek-linux-build:/build -w /work "$IMAGE" bash -euc '
  mkdir -p /work && cp -a /src/. /work/ && rm -rf /work/.build && ln -s /build /work/.build
  swift build --product sneekd
  for i in $(seq 1 '"$RUNS"'); do echo "== run $i"; timeout 300 swift run SneekTests; done
'
