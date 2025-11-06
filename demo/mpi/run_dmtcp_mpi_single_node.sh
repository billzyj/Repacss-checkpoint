#!/bin/bash
# ===== Slurm Job Info =====
#SBATCH --job-name=dmtcp_mpi_single
#SBATCH --output=dmtcp_mpi_single-%j.out
#SBATCH --error=dmtcp_mpi_single-%j.err
# ===== Slurm Resource Requests =====
#SBATCH --partition=zen4
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --mem=0
#SBATCH --time=02:00:00

set -euo pipefail

echo "===== Job ${SLURM_JOB_ID:-?} on ${SLURM_NODELIST:-?} ====="
echo "CPUs/task: ${SLURM_CPUS_PER_TASK:-1} | Tasks: ${SLURM_NTASKS:-?}"
echo "Working directory: $(pwd)"
echo

# ===== Environment =====
# Avoid TTY-only commands in non-interactive batch
source ~/.bashrc || true

# Prefer 'module' and fall back to 'ml' if needed
if command -v module >/dev/null 2>&1; then
  module purge
  module load gcc/14.2.0
  module load mpich/4.1.2         # MPICH path
elif command -v ml >/dev/null 2>&1; then
  ml purge
  ml gcc/14.2.0 mpich/4.1.2
else
  echo "WARNING: No module command found; assuming MPICH and DMTCP already in PATH."
fi

SRUN_MPI="--mpi=pmix"          

# Use job dir as checkpoint destination
export DMTCP_CHECKPOINT_DIR="$SLURM_SUBMIT_DIR/ckpt.$SLURM_JOB_ID"
export DMTCP_TMPDIR="$DMTCP_CHECKPOINT_DIR/tmp"
mkdir -p "$DMTCP_CHECKPOINT_DIR" "$DMTCP_TMPDIR"

# Use localhost for coordinator (single node)
COORD_HOST="localhost"
echo "Using localhost for coordinator"

# Keep coord files out of repo dir
COORD_PORT_FILE="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.port"
COORD_STATUS="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.status"
COORD_LOG="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.log"

# ---- Scrub potentially conflicting DMTCP/MANA env ----
unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT \
      DMTCP_PATH DMTCP_PLUGIN_PATH DMTCP_GZIP DMTCP_LD_LIBRARY_PATH

# --- coordinator start (daemon) ---
echo "Starting coordinator on localhost..."
which dmtcp_coordinator
dmtcp_coordinator --version || true

dmtcp_coordinator --daemon \
  --port 0 \
  --port-file "$COORD_PORT_FILE" \
  --status-file "$COORD_STATUS" \
  --coord-logfile "$COORD_LOG" \
  --interval 10 || echo 'ERROR: Coordinator startup failed'

sleep 2
echo "Checking coordinator process after startup..."
ps aux | grep -E '[d]mtcp_coordinator' || echo 'WARNING: No coordinator process found'

# wait for port file
for i in {1..40}; do [[ -s "$COORD_PORT_FILE" ]] && break; sleep 0.25; done
if [[ ! -s "$COORD_PORT_FILE" ]]; then
  echo "ERROR: Coordinator port file not found"
  [[ -f "$COORD_LOG" ]] && sed -n '1,200p' "$COORD_LOG" || true
  exit 1
fi

COORD_PORT="$(tr -d '[:space:]' < "$COORD_PORT_FILE")"
echo "Coordinator at ${COORD_HOST}:${COORD_PORT}"

# show status/PID if available
[[ -s "$COORD_STATUS" ]] && { echo "== coord status =="; sed -n '1,80p' "$COORD_STATUS"; }

# Verify coordinator process is running and check its listening sockets
echo "Verifying coordinator process..."
echo '== coordinator processes =='
ps aux | grep -E '[d]mtcp_coordinator' || echo 'No coordinator process found'
echo '== checking for port ${COORD_PORT} specifically =='
(ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ":${COORD_PORT}" || echo "Port ${COORD_PORT} NOT in listening sockets"

# --- authoritative readiness loop using dmtcp_command ---
echo "Waiting for coordinator readiness on ${COORD_HOST}:${COORD_PORT} ..."
READY=0
for i in {1..10}; do
  if dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.25
done
if [[ $READY -ne 1 ]]; then
  echo "WARNING: coordinator not responding after 10 attempts; recent coord log tail:"
  [[ -f "$COORD_LOG" ]] && tail -n 50 "$COORD_LOG" || true
  echo "Attempting to continue anyway..."
fi

# --- sockets & address info (diagnostic; non-fatal) ---
echo '== checking coordinator process =='
ps aux | grep -E '[d]mtcp_coordinator' || echo 'No coordinator process!'
echo '== coordinator listening on IPv4: =='
(ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ":${COORD_PORT}[[:space:]]" || echo "(port ${COORD_PORT} NOT found in IPv4 listening sockets)"
echo '== coordinator listening on IPv6: =='
(ss -H -ltn6 2>/dev/null || netstat -ltn6 2>/dev/null) | grep ":${COORD_PORT}[[:space:]]" || echo "(port ${COORD_PORT} NOT found in IPv6 listening sockets)"

# ===== Sanity on all rank slots =====
echo "== Sanity on all rank slots =="
srun $SRUN_MPI -N 1 -n "$SLURM_NTASKS" bash -lc '
  echo "TASK=$SLURM_PROCID HOST=$(hostname)"
  which dmtcp_launch || echo "MISSING: dmtcp_launch"
  dmtcp_launch --version 2>/dev/null | head -n1 || true
  test -x "'"$SLURM_SUBMIT_DIR"'/hello_mpi" || echo "MISSING OR NOT EXEC: hello_mpi"
' | sed 's/^/  /'

echo "== dmtcp_launch ldd (task 0 only) =="
srun $SRUN_MPI -N 1 -n 1 bash -lc '
  D=$(which dmtcp_launch 2>/dev/null) || exit 0
  echo "dmtcp_launch = $D"
  ldd "$D" | egrep "not found|mana|dmtcp" || true
'

echo "== Test: dmtcp_launch true (rank 0 only) =="
srun $SRUN_MPI -N 1 -n 1 bash -lc "dmtcp_launch true && echo OK_DMTCP_LAUNCH || echo FAIL_DMTCP_LAUNCH"

# ---- Launch ranks under DMTCP ----
export MAX_STEPS=120
echo "Launching MPI ranks under DMTCP..."
echo "dmtcp_launch wrapping srun with $SLURM_NTASKS tasks"

unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT
dmtcp_launch --join-coordinator \
  --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" \
  srun $SRUN_MPI -N 1 -n "$SLURM_NTASKS" "$SLURM_SUBMIT_DIR/hello_mpi" &
APP_PID=$!

# Let ranks connect; then list via explicit host/port
echo "Waiting for ranks to connect and initialize..."
sleep 10
echo "Processes visible to coordinator (after launch):"
dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list || true

# Check if ranks are connected
CONNECTED=$(dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list 2>/dev/null | grep -c "^[0-9]" || echo "0")
if [[ "$CONNECTED" == "0" ]]; then
  echo "WARNING: No ranks connected to coordinator. Checking rank logs for errors..."
  for log in rank.*.dmtcp_launch.log; do
    if [[ -f "$log" ]]; then
      echo "=== $log ==="
      tail -n 10 "$log" | head -n 5
    fi
  done
  echo ""
  echo "If ranks failed with 'shmctl' or 'sysvipc' errors, DMTCP cannot checkpoint this MPI implementation."
  echo "Use MANA (https://github.com/mpickpt/mana) for MPI checkpointing instead."
  wait "$APP_PID" || true
  exit 1
fi

echo "SUCCESS: All $CONNECTED ranks connected!"
echo ""
echo "Automatic checkpointing enabled: checkpoints will be created every 10 seconds"
echo "NOTE: By default, DMTCP overwrites previous checkpoints. Only the latest checkpoint is preserved."
echo "Waiting for application to complete..."
echo ""

# Wait for application to finish (checkpoints happen automatically every 10 seconds)
wait "$APP_PID" || {
  EXIT_CODE=$?
  echo "Application exited with code: $EXIT_CODE"
}

# List final state
echo ""
echo "Final coordinator state:"
dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list || true

echo ""
echo "Checkpoints saved in: $DMTCP_CHECKPOINT_DIR"

