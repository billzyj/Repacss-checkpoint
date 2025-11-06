#!/bin/bash
# ===== Slurm Job Info =====
#SBATCH --job-name=dmtcp_openmp_auto
#SBATCH --output=dmtcp_openmp_auto-%j.out
#SBATCH --error=dmtcp_openmp_auto-%j.err
# ===== Slurm Resource Requests =====
#SBATCH --partition=zen4
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --time=02:00:00

set -euo pipefail

echo "===== Job ${SLURM_JOB_ID:-?} on ${SLURM_NODELIST:-?} ====="
echo "CPUs: ${SLURM_CPUS_PER_TASK:-?} | Working directory: $(pwd)"
echo

# ===== Environment =====
source ~/.bashrc || true

# Load modules if available
if command -v module >/dev/null 2>&1; then
  module purge
  module load gcc/14.2.0
elif command -v ml >/dev/null 2>&1; then
  ml purge
  ml gcc/14.2.0
fi

# Set OpenMP threads to use all available cores
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-256}
echo "OMP_NUM_THREADS=$OMP_NUM_THREADS"

# Use job dir as checkpoint destination
export DMTCP_CHECKPOINT_DIR="$SLURM_SUBMIT_DIR/ckpt.$SLURM_JOB_ID"
export DMTCP_TMPDIR="$DMTCP_CHECKPOINT_DIR/tmp"
mkdir -p "$DMTCP_CHECKPOINT_DIR" "$DMTCP_TMPDIR"

# Use localhost for coordinator
COORD_HOST="localhost"

# Keep coord files out of repo dir
COORD_PORT_FILE="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.port"
COORD_STATUS="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.status"
COORD_LOG="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.log"

# ---- Scrub potentially conflicting DMTCP/MANA env ----
unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT \
      DMTCP_PATH DMTCP_PLUGIN_PATH DMTCP_GZIP DMTCP_LD_LIBRARY_PATH

# --- coordinator start (daemon) with automatic checkpoint interval ---
echo "Starting coordinator on localhost with 30-second checkpoint interval..."
which dmtcp_coordinator
dmtcp_coordinator --version || true

dmtcp_coordinator --daemon \
  --port 0 \
  --port-file "$COORD_PORT_FILE" \
  --status-file "$COORD_STATUS" \
  --coord-logfile "$COORD_LOG" \
  --interval 30 || echo 'ERROR: Coordinator startup failed'

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

# Verify coordinator process is running
echo "Verifying coordinator process..."
ps aux | grep -E '[d]mtcp_coordinator' || echo 'No coordinator process found'
echo "Checking for port ${COORD_PORT}:"
(ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ":${COORD_PORT}[[:space:]]" || echo "Port ${COORD_PORT} NOT in listening sockets"

# --- Wait for coordinator readiness ---
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

# ===== Sanity checks =====
echo "== Sanity checks =="
echo "Checking dmtcp_launch..."
which dmtcp_launch || echo "MISSING: dmtcp_launch"
dmtcp_launch --version 2>/dev/null | head -n1 || true

APP_PATH="$SLURM_SUBMIT_DIR/omp_dmtcp_demo"
if [[ ! -x "$APP_PATH" ]]; then
  echo "ERROR: $APP_PATH not found or not executable"
  exit 1
fi
echo "Application: $APP_PATH"

# Test dmtcp_launch with a simple command
echo "== Test: dmtcp_launch true =="
dmtcp_launch true && echo OK_DMTCP_LAUNCH || echo FAIL_DMTCP_LAUNCH

# ---- Launch OpenMP program under DMTCP ----
echo ""
echo "Launching OpenMP program under DMTCP with automatic checkpointing every 30 seconds..."
echo "Application will run with $OMP_NUM_THREADS OpenMP threads"
echo "NOTE: By default, DMTCP overwrites previous checkpoints. Only the latest checkpoint is preserved."
echo ""

# Set up checkpoint archiving (optional - uncomment to enable)
# ARCHIVE_CHECKPOINTS=true
ARCHIVE_CHECKPOINTS=false

if [[ "$ARCHIVE_CHECKPOINTS" == "true" ]]; then
  echo "Checkpoint archiving enabled - will preserve all checkpoints"
  # Monitor checkpoint directory and archive each new checkpoint
  (
    LAST_CHECKPOINT=""
    while true; do
      sleep 5
      # Find the latest checkpoint file
      LATEST=$(ls -t "$DMTCP_CHECKPOINT_DIR"/*.dmtcp 2>/dev/null | head -n1)
      if [[ -n "$LATEST" && "$LATEST" != "$LAST_CHECKPOINT" && -f "$LATEST" ]]; then
        # Extract generation from checkpoint if possible, or use timestamp
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        ARCHIVE_DIR="$DMTCP_CHECKPOINT_DIR/archived"
        mkdir -p "$ARCHIVE_DIR"
        ARCHIVE_NAME="$ARCHIVE_DIR/$(basename "$LATEST" .dmtcp)_gen${TIMESTAMP}.dmtcp"
        cp "$LATEST" "$ARCHIVE_NAME" 2>/dev/null && \
          echo "Archived checkpoint: $ARCHIVE_NAME" || true
        LAST_CHECKPOINT="$LATEST"
      fi
      # Exit if coordinator is no longer running
      if ! ps aux | grep -qE '[d]mtcp_coordinator'; then
        break
      fi
    done
  ) &
  ARCHIVE_PID=$!
fi

# Launch with automatic checkpoint interval (coordinator already set to 30s)
# The coordinator's --interval handles automatic checkpointing
dmtcp_launch --join-coordinator \
  --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" \
  "$APP_PATH" -s 120 -w 50 -F "$DMTCP_CHECKPOINT_DIR/state.txt" || {
  EXIT_CODE=$?
  echo "Application exited with code: $EXIT_CODE"
  [[ "$ARCHIVE_CHECKPOINTS" == "true" ]] && kill $ARCHIVE_PID 2>/dev/null || true
  exit $EXIT_CODE
}

# Stop archiving if enabled
[[ "$ARCHIVE_CHECKPOINTS" == "true" ]] && kill $ARCHIVE_PID 2>/dev/null || true

# List final state
echo ""
echo "Final coordinator state:"
dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list || true

echo ""
echo "Checkpoints saved in: $DMTCP_CHECKPOINT_DIR"
echo "State file: $DMTCP_CHECKPOINT_DIR/state.txt"
if [[ -f "$DMTCP_CHECKPOINT_DIR/state.txt" ]]; then
  echo "State file contents:"
  cat "$DMTCP_CHECKPOINT_DIR/state.txt"
fi

