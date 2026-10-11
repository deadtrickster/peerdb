#!/bin/bash
# Acceptance run, take 4. Takes 1-3 each died on a missing piece of the CI environment:
#   .env absent (my glob dropped dot-files) -> tilt had nothing
#   a stale Tilt process holding 10350 (`down` stops resources, not the process)
#   yq absent -> scripts/generate-test-environment.sh could not resolve image tags
#   .github/ absent (same glob) -> the same script could not read flow.yml
# The VM has been re-packed from the repaired copy, so the project tree is whole now; the
# root layer (Go, buf, tilt, yq) survived, and only the generated protos have to be redone.
set -x
R=/var/folders/dd/r86fv54927ndyx8wc8mtp2_40000gn/T/letibot-501/scratch-34238/e2e
cd "$R" || exit 2
export TZ=UTC PATH=/usr/local/go/bin:$PATH

echo "=== 0. is the tree whole this time?"
ls -la .env.example .github/workflows/flow.yml | head -3

echo "=== 0b. protos (project drive was re-packed, so these are gone again)"
command -v buf >/dev/null 2>&1 || { curl -fsSL -o /tmp/buf https://github.com/bufbuild/buf/releases/latest/download/buf-Linux-aarch64 && sudo install -m0755 /tmp/buf /usr/local/bin/buf; }
./generate-protos.sh >/tmp/genprotos4.log 2>&1; echo "GENPROTOS=$?"; tail -1 /tmp/genprotos4.log

echo "=== 0c. yq + env + the generator"
command -v yq >/dev/null 2>&1 || { curl -fsSL -o /tmp/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 && sudo install -m0755 /tmp/yq /usr/local/bin/yq; }
yq --version
cp -f .env.example .env
bash ./scripts/generate-test-environment.sh >/tmp/genenv4.log 2>&1; echo "GENENV=$?"; tail -2 /tmp/genenv4.log
wc -l ancillary.env 2>/dev/null

echo "=== 0d. free 10350 by pid"
for attempt in 1 2 3; do
  pid=$(ss -lntp 2>/dev/null | sed -n 's/.*:10350 .*pid=\([0-9]*\).*/\1/p' | head -1)
  [ -z "$pid" ] && { echo "port free (attempt ${attempt})"; break; }
  sudo kill "$pid" 2>/dev/null || true; sleep 3
done

echo "=== 1. tilt up"
setsid nohup tilt up --port 10350 >/tmp/tiltup5.log 2>&1 &
for i in $(seq 1 120); do
  tilt --port 10350 get uiresources >/dev/null 2>&1 && { echo "TILT_API_UP after ${i}"; break; }
  sleep 2
done
echo "--- resources tilt knows ---"
tilt --port 10350 get uiresources --no-headers 2>/dev/null | awk '{print $1}' | head -30
tail -3 /tmp/tiltup5.log

echo "=== 2. ancillary postgres pair"
tilt --port 10350 enable postgres postgres2 >>/tmp/tiltup5.log 2>&1; echo "ENABLE=$?"
for s in postgres postgres2; do tilt --port 10350 trigger "$s" >>/tmp/tiltup5.log 2>&1; done
for s in postgres postgres2; do
  tilt --port 10350 wait --for=condition=Ready "uiresource/$s" --timeout=900s >/dev/null 2>&1
  echo "ANCILLARY_${s}=$?"
done

echo "=== 3. core services"
for s in proto-gen catalog flow-migrate flow-api flow-worker flow-snapshot-worker minio; do
  tilt --port 10350 wait --for=condition=Ready "uiresource/$s" --timeout=900s >/dev/null 2>&1
  echo "CORE_${s}=$?"
done

echo "=== 4. the e2e test"
cd "$R/flow" && go test -tags tilt ./e2e/postgres_postgres/ \
  -run 'TestPeerFlowE2ETestSuitePG/Test_Complete_QRep_Flow_Multi_Insert_PG' -timeout 30m >/tmp/e2e5.log 2>&1
echo "E2E=$?"
tail -30 /tmp/e2e5.log

echo "=== 5. disk cost of the stack"
sudo docker system df 2>/dev/null | head -4
df -h / | tail -1
