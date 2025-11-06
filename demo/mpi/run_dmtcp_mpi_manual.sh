#!/bin/bash
# ===== Slurm Job Info =====
#SBATCH --job-name=dmtcp_mpi_demo
#SBATCH --output=dmtcp_mpi_demo-%j.out
#SBATCH --error=dmtcp_mpi_demo-%j.err
# ===== Slurm Resource Requests =====
#SBATCH --partition=zen4
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
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

# Define MPI backend BEFORE any srun (MPICH => PMI2)
SRUN_MPI="--mpi=pmi2"            # do NOT load/use pmix with MPICH

# Use job dir as checkpoint destination
export DMTCP_CHECKPOINT_DIR="$SLURM_SUBMIT_DIR/ckpt.$SLURM_JOB_ID"
export DMTCP_TMPDIR="$DMTCP_CHECKPOINT_DIR/tmp"
mkdir -p "$DMTCP_CHECKPOINT_DIR" "$DMTCP_TMPDIR"

# Pick one host to run the coordinator
FIRST_NODE=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
echo "First node for coordinator: $FIRST_NODE"

# Use HOSTNAME for join-coordinator to avoid "remote host" guard in dmtcp_launch
COORD_HOST="$FIRST_NODE"

# Keep coord files out of repo dir
COORD_PORT_FILE="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.port"
COORD_STATUS="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.status"
COORD_LOG="$DMTCP_TMPDIR/coord.${SLURM_JOB_ID}.log"

# ---- Scrub potentially conflicting DMTCP/MANA env ----
unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT \
      DMTCP_PATH DMTCP_PLUGIN_PATH DMTCP_GZIP DMTCP_LD_LIBRARY_PATH

# --- coordinator start (daemon) ---
# Get the IP address of the first node for connection purposes (coordinator binds to all interfaces by default)
# Try grep -oP first, fall back to sed if not available
FIRST_NODE_IP=$(srun -N1 -n1 -w "$FIRST_NODE" bash -lc "
  ip -4 addr show | grep -oP 'inet \K[0-9.]+' 2>/dev/null | grep -v '^127\.' | head -n1 || \
  ip -4 addr show | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | grep -v '^127\.' | head -n1
" 2>/dev/null || echo "")

if [[ -n "$FIRST_NODE_IP" ]]; then
  echo "First node IP detected: $FIRST_NODE_IP (will use for connections)"
else
  echo "Could not detect first node IP, will use hostname for connections"
fi

srun -N1 -n1 -w "$FIRST_NODE" bash -lc "
  which dmtcp_coordinator
  dmtcp_coordinator --version || true
  echo 'Starting coordinator in daemon mode...'
  dmtcp_coordinator --daemon \
    --port 0 \
    --port-file '$COORD_PORT_FILE' \
    --status-file '$COORD_STATUS' \
    --coord-logfile '$COORD_LOG' || echo 'ERROR: Coordinator startup failed'
  sleep 2
  echo 'Checking coordinator process after startup...'
  ps aux | grep -E '[d]mtcp_coordinator' || echo 'WARNING: No coordinator process found'
"

# wait for port file
for i in {1..40}; do [[ -s "$COORD_PORT_FILE" ]] && break; sleep 0.25; done
if [[ ! -s "$COORD_PORT_FILE" ]]; then
  echo "ERROR: Coordinator port file not found"
  [[ -f "$COORD_LOG" ]] && sed -n '1,200p' "$COORD_LOG" || true
  exit 1
fi

COORD_PORT="$(tr -d '[:space:]' < "$COORD_PORT_FILE")"

# Verify coordinator process is running and check its listening sockets
echo "Verifying coordinator process..."
srun -N1 -n1 -w "$FIRST_NODE" bash -lc "
  echo '== coordinator processes =='
  ps aux | grep -E '[d]mtcp_coordinator' || echo 'No coordinator process found'
  echo '== listening sockets (all ports) =='
  (ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | head -n 20 || true
  echo '== checking for port ${COORD_PORT} specifically =='
  (ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':${COORD_PORT}' || echo 'Port ${COORD_PORT} NOT in listening sockets'
" || true

# Determine connection address: prefer the IP we bound to, then extract from status file
COORD_IP=""
if [[ -n "$FIRST_NODE_IP" && "$FIRST_NODE_IP" != "0.0.0.0" ]]; then
  # Use the IP we explicitly bound to
  COORD_IP="$FIRST_NODE_IP"
elif [[ -s "$COORD_STATUS" ]]; then
  echo "== coord status =="
  sed -n '1,80p' "$COORD_STATUS"
  # Extract IP from "Host: hostname (IP)" pattern - try Perl regex first, then sed fallback
  COORD_IP=$(grep -oP 'Host:.*\(\K[0-9.]+(?=\))' "$COORD_STATUS" 2>/dev/null | head -n1 || \
             sed -n 's/.*Host:.*(\([0-9.]*\)).*/\1/p' "$COORD_STATUS" 2>/dev/null | head -n1 || true)
fi

# Use IP if available, otherwise use hostname
if [[ -n "$COORD_IP" && "$COORD_IP" != "0.0.0.0" ]]; then
  echo "Coordinator at ${COORD_HOST} (${COORD_IP}):${COORD_PORT}"
  COORD_HOST_CONNECT="$COORD_IP"
else
  echo "Coordinator at ${COORD_HOST}:${COORD_PORT}"
  COORD_HOST_CONNECT="$COORD_HOST"
fi

# --- authoritative readiness loop using dmtcp_command ---
echo "Waiting for coordinator readiness on ${COORD_HOST_CONNECT}:${COORD_PORT} ..."
READY=0
for i in {1..10}; do
  if srun -N1 -n1 -w "$FIRST_NODE" bash -lc \
      "dmtcp_command --coord-host '$COORD_HOST_CONNECT' --coord-port '$COORD_PORT' --list >/dev/null 2>&1" 2>/dev/null; then
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
srun -N1 -n1 -w "$FIRST_NODE" bash -lc "
  echo '== checking coordinator process =='
  ps aux | grep -E '[d]mtcp_coordinator' || echo 'No coordinator process!'
  echo '== coordinator listening on IPv4: =='
  (ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':${COORD_PORT}\$' || echo '(port ${COORD_PORT} NOT found in IPv4 listening sockets)'
  echo '== coordinator listening on IPv6: =='
  (ss -H -ltn6 2>/dev/null || netstat -ltn6 2>/dev/null) | grep ':${COORD_PORT}\$' || echo '(port ${COORD_PORT} NOT found in IPv6 listening sockets)'
  echo '== all listening TCP ports (first 30): =='
  (ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | head -n 30 || true
  echo '== all IPv4 addresses on this node: =='
  ip -4 addr show | grep -oP 'inet \K[0-9.]+' || ip -4 addr show | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' || true
" 2>/dev/null || true

# --- cross-node TCP probe (diagnostic; non-fatal) ---
SECOND_NODE=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | sed -n '2p')
if [[ -n "$SECOND_NODE" ]]; then
  echo "TCP probe from $SECOND_NODE to $COORD_HOST_CONNECT:$COORD_PORT ..."
  srun -N1 -n1 -w "$SECOND_NODE" bash -lc "timeout 2 bash -c '</dev/tcp/$COORD_HOST_CONNECT/$COORD_PORT' && echo CONNECT_OK || echo CONNECT_FAIL" 2>/dev/null || true
fi

# ===== Sanity on all rank slots =====
echo "== Sanity on all rank slots =="
srun $SRUN_MPI -N "$SLURM_NNODES" -n "$SLURM_NTASKS" bash -lc '
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

# ---- Launch ranks under DMTCP (per-rank logs) ----
export MAX_STEPS=120
echo "Launching MPI ranks under DMTCP (per-rank logs)..."
srun $SRUN_MPI -N "$SLURM_NNODES" -n "$SLURM_NTASKS" bash -lc '
  set -e
  R=${SLURM_PROCID:-X}
  LOG="rank.${R}.dmtcp_launch.log"
  {
    echo "[${HOSTNAME}] rank=$R PATH=$PATH"
    echo "[${HOSTNAME}] rank=$R joining '"$COORD_HOST_CONNECT:$COORD_PORT"'"
  } > "$LOG"
  unset DMTCP_COORD_HOST DMTCP_COORD_PORT DMTCP_HOST DMTCP_PORT
  dmtcp_launch --join-coordinator \
    --coord-host "'"$COORD_HOST_CONNECT"'" --coord-port "'"$COORD_PORT"'" \
    "'"$SLURM_SUBMIT_DIR"'/hello_mpi" >> "$LOG" 2>&1
' &
APP_PID=$!

# Let ranks connect; then list via explicit host/port
sleep 5
echo "Processes visible to coordinator (after launch):"
srun -N1 -n1 -w "$FIRST_NODE" bash -lc '
  dmtcp_command --coord-host "'"$COORD_HOST_CONNECT"'" --coord-port "'"$COORD_PORT"'" --list
' || true

# Checkpoint after ~30s
sleep 30
echo "Requesting a checkpoint..."
srun -N1 -n1 -w "$FIRST_NODE" bash -lc '
  dmtcp_command --coord-host "'"$COORD_HOST_CONNECT"'" --coord-port "'"$COORD_PORT"'" --checkpoint
'

# List again
srun -N1 -n1 -w "$FIRST_NODE" bash -lc '
  dmtcp_command --coord-host "'"$COORD_HOST_CONNECT"'" --coord-port "'"$COORD_PORT"'" --list
' || true

wait "$APP_PID" || true