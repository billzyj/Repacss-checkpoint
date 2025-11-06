#!/bin/bash
# ===== Slurm Job Info =====
#SBATCH --job-name=dmtcp_mpi_restart
#SBATCH --output=dmtcp_mpi_restart-%j.out
#SBATCH --error=dmtcp_mpi_restart-%j.err
# ===== Slurm Resource Requests =====
#SBATCH --partition=zen4
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --mem=0
#SBATCH --time=02:00:00

set -euo pipefail

echo "===== Restart Job ${SLURM_JOB_ID:-?} on ${SLURM_NODELIST:-?} ====="
echo "CPUs/task: ${SLURM_CPUS_PER_TASK:-1} | Tasks: ${SLURM_NTASKS:-?}"
echo "Working directory: $(pwd)"
echo

# ===== Configuration =====
# Path to the checkpoint directory from original run
# Update this to point to your checkpoint directory
ORIGINAL_CKPT_DIR="${1:-/mnt/REPACSS/home/yongzhao/research_projects/Repacss-checkpoint/demo/mpi/ckpt.21385}"

if [[ ! -d "$ORIGINAL_CKPT_DIR" ]]; then
  echo "ERROR: Checkpoint directory not found: $ORIGINAL_CKPT_DIR"
  echo "Usage: sbatch restart_dmtcp_mpi.sh [CHECKPOINT_DIRECTORY]"
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
  module load mpich/4.1.2
elif command -v ml >/dev/null 2>&1; then
  ml purge
  ml gcc/14.2.0 mpich/4.1.2
else
  echo "WARNING: No module command found; assuming MPICH and DMTCP already in PATH."
fi

# Define MPI backend BEFORE any srun
SRUN_MPI="--mpi=pmix"

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

# Get checkpoint interval from original run (default 10 if not available)
CHECKPOINT_INTERVAL=10
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
export DMTCP_CHECKPOINT_DIR="$DMTCP_CHECKPOINT_DIR"  # Ensure checkpoint dir is set

# Call the original restart script with updated coordinator info
# The restart script will use --coord-host and --coord-port to override defaults
echo "Executing restart script..."
echo "Note: dmtcp_restart uses exec, so output may not appear immediately."
echo "Application will run in background - monitoring coordinator for completion..."
echo "Checkpoint directory for new checkpoints: $DMTCP_CHECKPOINT_DIR"
echo ""

# Change to checkpoint directory so dmtcp_restart creates new checkpoints there
# dmtcp_restart may use current working directory for new checkpoints
cd "$DMTCP_CHECKPOINT_DIR" || {
  echo "ERROR: Cannot change to checkpoint directory: $DMTCP_CHECKPOINT_DIR"
  exit 1
}

# Run restart script in background - it uses exec so it will replace the bash process
# We need to monitor the coordinator to detect when application finishes
bash "$RESTART_SCRIPT" \
  --coord-host "$COORD_HOST" \
  --coord-port "$COORD_PORT" \
  --restartdir "$ORIGINAL_CKPT_DIR" \
  --ckptdir "$DMTCP_CHECKPOINT_DIR" \
  --interval "$CHECKPOINT_INTERVAL" \
  > "$DMTCP_CHECKPOINT_DIR/restart_output.log" \
  2> "$DMTCP_CHECKPOINT_DIR/restart_error.log" &
RESTART_PID=$!

# Change back to original directory for monitoring
cd "$SLURM_SUBMIT_DIR" || cd "$OLDPWD" || true

echo "Restart process PID: $RESTART_PID"
echo "Monitoring coordinator for application completion..."
echo ""

# Monitor coordinator - wait for processes to disconnect (application finished)
MAX_WAIT=3600  # 1 hour max
WAIT_TIME=0
CHECK_INTERVAL=5
PREV_CONNECTED=-1

while [[ $WAIT_TIME -lt $MAX_WAIT ]]; do
  sleep $CHECK_INTERVAL
  WAIT_TIME=$((WAIT_TIME + CHECK_INTERVAL))
  
  # Check coordinator for connected processes
  CONNECTED=$(dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list 2>/dev/null | grep -c "^[0-9]" || echo "0")
  
  # Check if restart process is still running
  if ! kill -0 "$RESTART_PID" 2>/dev/null; then
    # Process finished - wait for it and check exit code
    wait "$RESTART_PID" 2>/dev/null || true
    EXIT_CODE=$?
    echo ""
    echo "Restart process completed with exit code: $EXIT_CODE"
    break
  fi
  
  # Show progress every 30 seconds
  if [[ $((WAIT_TIME % 30)) -eq 0 ]]; then
    if [[ $CONNECTED -ne $PREV_CONNECTED ]]; then
      echo "[$(date '+%H:%M:%S')] Processes connected to coordinator: $CONNECTED"
      PREV_CONNECTED=$CONNECTED
    fi
    
    # If no processes connected, application might have finished
    if [[ $CONNECTED -eq 0 ]] && [[ $PREV_CONNECTED -gt 0 ]]; then
      echo "[$(date '+%H:%M:%S')] All processes disconnected - application may have completed"
      # Wait a bit more to see if restart process exits
      sleep 2
      if ! kill -0 "$RESTART_PID" 2>/dev/null; then
        wait "$RESTART_PID" 2>/dev/null || true
        EXIT_CODE=$?
        break
      fi
    fi
  fi
done

# Final check
if [[ $WAIT_TIME -ge $MAX_WAIT ]]; then
  echo ""
  echo "WARNING: Maximum wait time reached. Application may still be running."
  echo "Current coordinator state:"
  dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list 2>/dev/null || echo "Coordinator not responding"
fi

# Show captured output
echo ""
echo "=== Application Output ==="
cat "$DMTCP_CHECKPOINT_DIR/restart_output.log" 2>/dev/null || echo "(no output captured)"
if [[ -s "$DMTCP_CHECKPOINT_DIR/restart_error.log" ]]; then
  echo ""
  echo "=== Errors/Warnings ==="
  cat "$DMTCP_CHECKPOINT_DIR/restart_error.log"
fi

# List final state
echo ""
echo "Final coordinator state:"
dmtcp_command --coord-host "$COORD_HOST" --coord-port "$COORD_PORT" --list || true

echo ""
echo "Restart completed. New checkpoints saved in: $DMTCP_CHECKPOINT_DIR"

