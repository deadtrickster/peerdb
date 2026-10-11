#!/bin/bash
# 01 - Go 1.27.1 + libgeos (cgo dep of go-geos) + the flow binary from this checkout.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
# Derived from this script's own location, NOT hardcoded. The first run hardcoded the
# author's scratch path, so the recipe could only ever run in that one directory - which is
# exactly what a firecode child discovered when its copy of the tree was somewhere else.
REPO=$(cd "$(dirname "$0")/.." && pwd)

sudo apt-get install -y curl gcc libgeos-dev pkg-config

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) GOARCH=arm64 ;;
  x86_64|amd64)  GOARCH=amd64 ;;
  *) echo "unknown arch $ARCH" >&2; exit 1 ;;
esac
GOVER=1.27.1

if [ ! -x /usr/local/go/bin/go ]; then
  curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GOVER}.linux-${GOARCH}.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH=/usr/local/go/bin:$PATH
go version

# protos are already generated in the tree (flow/generated) - no buf needed.
cd "$REPO/flow"
# -p=1 deliberately. With the default (-p = NumCPU) the compiler peaked at 2.5GB RSS
# and the 4GB guest's OOM killer took it; `go build` then exits 1 with NO compiler
# error and an empty log, and only dmesg says why. Serialize it, or boot with --mem 8192.
time env GOFLAGS=-p=1 GOMAXPROCS=2 GOGC=30 go build -o /tmp/peerflow .
# /usr/local/bin is root-owned and the guest user is uid 501, so the install is the
# one step that needs sudo. (Building straight to /usr/local/bin fails at the very
# end of a successful compile with "open /usr/local/bin/peerflow: permission denied".)
sudo install -m 0755 /tmp/peerflow /usr/local/bin/peerflow
echo "--- the four subcommands this binary must have ---"
/usr/local/bin/peerflow --help
echo "--- api flags, so the port/namespace wiring is on the record ---"
/usr/local/bin/peerflow api --help || true
echo "01-toolchain.sh OK"
