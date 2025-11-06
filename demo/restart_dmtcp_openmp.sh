#!/bin/bash
# ===== Slurm Job Info =====
#SBATCH --job-name=dmtcp_openmp_restart
#SBATCH --output=dmtcp_openmp_restart-%j.out
#SBATCH --error=dmtcp_openmp_restart-%j.err
# ===== Slurm Resource Requests =====
#SBATCH --partition=zen4
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=256
#SBATCH --mem=0
#SBATCH --time=02:00:00

set -euo pipefail

echo "===== Restart Job ${SLURM_JOB_ID:-?} on ${SLURM_NODELIST:-?} ====="
echo "CPUs: ${SLURM_CPUS_PER_TASK:-?} | Working directory: $(pwd)"
echo

# ===== Configuration =====
# Path to the checkpoint directory from original run
# Update this to point to your checkpoint directory
ORIGINAL_CKPT_DIR="${1:-/mnt/REPACSS/home/yongzhao/research_projects/Repacss-checkpoint/demo/ckpt.21373}"

if [[ ! -d "$ORIGINAL_CKPT_DIR" ]]; then
  echo "ERROR: Checkpoint directory not found: $ORIGINAL_CKPT_DIR"
  echo "Usage: sbatch restart_dmtcp_openmp.sh [CHECKPOINT_DIRECTORY]"
  exit 1
fi

# Path to the restart script (should be in the checkpoint directory)
RESTART_SCRIPT="$ORIGINAL_CKPT_DIR/dmtcp_restart_script.sh"

if [[ ! -f "$RESTART_SCRIPT" ]]; then
  echo "ERROR: Restart script not found: $RESTART_SCRIPT"
  exit 1
fi

echo "Checkpoint directory: $ORIGINAL_CKPT_DIR"
echo "Restart script: $RESTART_SCRIPT"
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

# Use job dir for new coordinator files
export DMTCP_CHECKPOINT_DIR="$SLURM_SUBMIT_DIR/ckpt.restart.$SLURM_JOB_ID"
export DMTCP_TMPDIR="$DMTCP_CHECKPOINT_DIR/tmp"
mkdir -p "$DMTCP_CHECKPOINT_DIR" "$DMTCP_TMPDIR"

# Use localhost for new coordinator (on restart node)
COORD_HOST="localhost"

# Keep coord files out of repo dir
COORD_PORT_FILE="$DMTCP_TMPDIR/coord.restart.${SLURM_JOB_ID}.port"
COORD_STATUS="$DMTCP_TMPDIR/coord.restart.${SLURM_JOB_ID}.status"
COORD_LOG="$DMTCP_TMPDIR/coord.restart.${SLURM_JOB_ID}.log"

# ---- Scrub potentially conflicting DMTCP/MANA env ----
unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT \
      DMTCP_PATH DMTCP_PLUGIN_PATH DMTCP_GZIP DMTCP_LD_LIBRARY_PATH

# --- Start new coordinator on restart node ---
echo "Starting new coordinator on localhost for restart..."
which dmtcp_coordinator
dmtcp_coordinator --version || true

# Get checkpoint interval from original run (default 30 if not available)
CHECKPOINT_INTERVAL=30
if [[ -f "$ORIGINAL_CKPT_DIR/dmtcp_restart_script.sh" ]]; then
  # Try to extract interval from restart script
  EXTRACTED_INTERVAL=$(grep -oP 'checkpoint_interval=\K[0-9]+' "$ORIGINAL_CKPT_DIR/dmtcp_restart_script.sh" 2>/dev/null | head -n1 || echo "")
  if [[ -n "$EXTRACTED_INTERVAL" ]]; then
    CHECKPOINT_INTERVAL="$EXTRACTED_INTERVAL"
  fi
fi

echo "Using checkpoint interval: $CHECKPOINT_INTERVAL seconds"

dmtcp_coordinator --daemon \
  --port 0 \
  --port-file "$COORD_PORT_FILE" \
  --status-file "$COORD_STATUS" \
  --coord-logfile "$COORD_LOG" \
  --interval "$CHECKPOINT_INTERVAL" || echo 'ERROR: Coordinator startup failed'

sleep 2
echo "Checking coordinator process after startup..."
ps aux | grep -E '[d]mtcp_coordinator' || echo 'WARNING: No coordinator process found'

# Wait for port file
for i in {1..40}; do [[ -s "$COORD_PORT_FILE" ]] && break; sleep 0.25; done
if [[ ! -s "$COORD_PORT_FILE" ]]; then
  echo "ERROR: Coordinator port file not found"
  [[ -f "$COORD_LOG" ]] && sed -n '1,200p' "$COORD_LOG" || true
  exit 1
fi

COORD_PORT="$(tr -d '[:space:]' < "$COORD_PORT_FILE")"
echo "New coordinator at ${COORD_HOST}:${COORD_PORT}"

# Show status/PID if available
[[ -s "$COORD_STATUS" ]] && { echo "== coord status =="; sed -n '1,80p' "$COORD_STATUS"; }

# Wait for coordinator readiness
echo "Waiting for coordinator readiness..."
READY=0
for i in {1..10}; do
  if dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.25
done
if [[ $READY -ne 1 ]]; then
  echo "WARNING: coordinator not responding after 10 attempts"
  [[ -f "$COORD_LOG" ]] && tail -n 50 "$COORD_LOG" || true
  echo "Attempting to continue anyway..."
fi

# ===== Restart from checkpoint =====
echo ""
echo "Restarting from checkpoint..."
echo "Original checkpoint directory: $ORIGINAL_CKPT_DIR"
echo "New coordinator: $COORD_HOST:$COORD_PORT"
echo ""

# Set environment variables for restart
export DMTCP_COORD_HOST="$COORD_HOST"
export DMTCP_COORD_PORT="$COORD_PORT"
export DMTCP_CHECKPOINT_INTERVAL="$CHECKPOINT_INTERVAL"
export DMTCP_RESTART_DIR="$ORIGINAL_CKPT_DIR"  # Directory containing checkpoint files
export DMTCP_CKPT_DIR="$DMTCP_CHECKPOINT_DIR"  # Directory for new checkpoints

# Call the original restart script with updated coordinator info
# The restart script will use --coord-host and --coord-port to override defaults
bash "$RESTART_SCRIPT" \
  --coord-host "$COORD_HOST" \
  --coord-port "$COORD_PORT" \
  --restartdir "$ORIGINAL_CKPT_DIR" \
  --ckptdir "$DMTCP_CHECKPOINT_DIR" \
  --interval "$CHECKPOINT_INTERVAL" \
  || {
  EXIT_CODE=$?
  echo "Restart exited with code: $EXIT_CODE"
  exit $EXIT_CODE
}

# List final state
echo ""
echo "Final coordinator state:"
dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list || true

echo ""
echo "Restart completed. New checkpoints saved in: $DMTCP_CHECKPOINT_DIR"
echo "State file: $ORIGINAL_CKPT_DIR/state.txt"
if [[ -f "$ORIGINAL_CKPT_DIR/state.txt" ]]; then
  echo "State file contents:"
  tail -n 10 "$ORIGINAL_CKPT_DIR/state.txt"
fi

