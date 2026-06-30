#!/bin/bash
#
# =============================================================================
# load_models.sh - Pre-download Hugging Face models onto ARENA pods
# =============================================================================
#
# TLDR: SSHes into pods (in parallel) and downloads the LLM weights into the
#       default HF cache, so participants' from_pretrained(...) calls work
#       offline with no path configuration.
#
# WHAT IT DOES (per pod, in a single SSH session):
#   1. Receives your HF token over SSH stdin (never in argv / ps) and writes it
#      to ~/.cache/huggingface/token (mode 600) so huggingface_hub can auth.
#   2. Downloads the models in MODELS[] into ~/.cache/huggingface/hub using the
#      conda env from config.env (CONDA_ENV_NAME).
#   3. Removes the token via a `trap ... EXIT` that fires on success, on
#      failure, AND if the connection drops mid-download -- so the token is
#      never left sitting on a box the participants will use.
#   4. Verifies each model loads from the cache offline.
#
# USAGE:
#   ./load_models.sh --token <HF_TOKEN> [pod ...]
#
#   --token <HF_TOKEN>   (required) Hugging Face token (e.g. hf_xxx). The
#                        account must already be granted access to any gated
#                        repos (the meta-llama models are gated).
#   [pod ...]            (optional) One or more pods to target. Accepts either
#                        the machine name ("gabby") or the full host name
#                        ("arbox4-gabby"). If omitted, targets every machine in
#                        MACHINE_NAME_LIST.
#
# EXAMPLES:
#   # Test on a single box first:
#   ./load_models.sh --token hf_xxx gabby
#
#   # Roll out to all pods:
#   ./load_models.sh --token hf_xxx
#
# LOGS:
#   Individual: ./logs/load-models-<host>.log
# =============================================================================

set -u

# --- Argument Parsing ---
HF_TOKEN=""
TARGETS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --token)
      HF_TOKEN="$2"
      shift 2
      ;;
    --token=*)
      HF_TOKEN="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Usage: $0 --token <HF_TOKEN> [pod ...]"
      exit 1
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$HF_TOKEN" ]; then
  echo "ERROR: --token <HF_TOKEN> is required."
  echo "Usage: $0 --token <HF_TOKEN> [pod ...]"
  exit 1
fi

# Load config.env from parent directory (MACHINE_NAME_LIST, MACHINE_NAME_PREFIX,
# SHARED_SSH_KEY_PATH, CONDA_ENV_NAME, MAX_PARALLEL)
source "$(dirname "$0")/../config.env"
logdir="$(dirname "$0")/../logs"
mkdir -p "$logdir"

# --- Configuration ---
SSH_KEY_PATH="$SHARED_SSH_KEY_PATH"
SSH_USER="root"
CONDA_ENV="${CONDA_ENV_NAME:-arena-env}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"

# Keepalives are essential: model downloads stall for tens of seconds while the
# HF Xet backend retries, and without these the (proxied) SSH session is torn
# down mid-download. 30s * 20 tolerates ~10 min of dead air before giving up.
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
  -o TCPKeepAlive=yes
  -i "$SSH_KEY_PATH"
)

# Models to download. Edit this list to change what gets pre-loaded.
# Both repos ship safetensors, so we exclude the duplicate pytorch_model*.bin
# and consolidated original/*.pth weights (see EXCLUDE_GLOBS below) -- this
# roughly halves Llama-2-13b-hf, which otherwise pulls ~52GB of both formats.
MODELS=(
  "meta-llama/Llama-2-13b-hf"
  "meta-llama/Meta-Llama-3.1-8B-Instruct"
)
# --- End Configuration ---

# --- Resolve target machine list ---
# Each target may be given as a bare machine name ("gabby") or as a full host
# name ("arbox4-gabby"); strip the prefix to normalise to the machine name.
machine_list=()
if [ ${#TARGETS[@]} -gt 0 ]; then
  for t in "${TARGETS[@]}"; do
    if [[ "$t" == "${MACHINE_NAME_PREFIX}-"* ]]; then
      machine_list+=("${t#${MACHINE_NAME_PREFIX}-}")
    else
      machine_list+=("$t")
    fi
  done
else
  machine_list=("${MACHINE_NAME_LIST[@]}")
fi

if [ ! -f "$SSH_KEY_PATH" ] && [ ! -f "${SSH_KEY_PATH/#\~/$HOME}" ]; then
  echo "ERROR: SSH key for connecting to pods not found at $SSH_KEY_PATH"
  exit 1
fi

echo "Target machines (${#machine_list[@]}): ${machine_list[*]}"
echo "Models: ${MODELS[*]}"
echo "Conda env: $CONDA_ENV | Max parallel: $MAX_PARALLEL"
echo

# Build the remote download/verify commands once (model list is identical per host).
# Skip duplicate weight formats we don't load: bin shards, consolidated .pth,
# and the original/ checkpoint dir. Both target models have safetensors.
EXCLUDE_GLOBS="--exclude 'original/*' '*.pth' 'pytorch_model*.bin'"
download_cmds=""
for m in "${MODELS[@]}"; do
  download_cmds+="echo \"--- Downloading ${m} ---\"
\"\$CONDA_BIN\" run --no-capture-output -n \"\$CONDA_ENV\" huggingface-cli download \"${m}\" ${EXCLUDE_GLOBS}
"
done
# Python verify: load every model's config from the local cache, offline.
verify_models_py="$(printf "'%s', " "${MODELS[@]}")"

# Function to process a single host
process_host() {
  local machine_name="$1"
  local pod_hostname="${MACHINE_NAME_PREFIX}-${machine_name}"
  local logfile="$logdir/load-models-${pod_hostname}.log"

  echo "--- Loading models on ${pod_hostname} ---" > "$logfile"
  date >> "$logfile"

  # Connection test
  if ! ssh -q -o BatchMode=yes -o ConnectTimeout=10 \
        "${SSH_OPTS[@]}" "${SSH_USER}@${pod_hostname}" exit; then
    echo "[${pod_hostname}] ERROR: SSH connection failed. Skipping." | tee -a "$logfile"
    echo "[SKIP] ${pod_hostname} (connection failed)"
    return 1
  fi

  # Everything runs in ONE remote bash so the EXIT trap guarantees token cleanup
  # even if the download fails or the connection drops. The token is expanded
  # into the heredoc locally and travels over SSH stdin -- it is never placed in
  # argv, so it does not appear in `ps` on either side. Remote-side expansions
  # are escaped as \$ ; local-side (${HF_TOKEN}, ${CONDA_ENV}, $download_cmds,
  # $verify_models_py) are expanded here.
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${pod_hostname}" "bash -s" <<EOF >> "$logfile" 2>&1
set -e
CONDA_ENV='${CONDA_ENV}'
# conda is usually not on PATH for a non-interactive shell (see test_em.sh).
CONDA_BIN="\$(command -v conda || echo /opt/conda/bin/conda)"
TOKEN_FILE="\$HOME/.cache/huggingface/token"
trap 'rm -f "\$TOKEN_FILE"; echo "[cleanup] removed HF token"' EXIT

umask 077
mkdir -p "\$HOME/.cache/huggingface"
printf '%s' '${HF_TOKEN}' > "\$TOKEN_FILE"
export HF_HUB_DISABLE_PROGRESS_BARS=1

# Ensure the HF CLI is available in the conda env.
if ! "\$CONDA_BIN" run -n "\$CONDA_ENV" bash -c 'command -v huggingface-cli' >/dev/null 2>&1; then
  echo "huggingface-cli not found in \$CONDA_ENV; installing huggingface_hub..."
  "\$CONDA_BIN" run --no-capture-output -n "\$CONDA_ENV" pip install -U 'huggingface_hub[cli]'
fi

${download_cmds}

echo "--- Verifying cached models load offline ---"
"\$CONDA_BIN" run --no-capture-output -n "\$CONDA_ENV" \
  env HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  python -c "from transformers import AutoConfig
for m in [${verify_models_py}]:
    AutoConfig.from_pretrained(m)
    print('verified', m)"
echo "ALL_MODELS_OK"
EOF

  if grep -q "ALL_MODELS_OK" "$logfile"; then
    echo "[OK] ${pod_hostname}"
  else
    echo "[FAIL] ${pod_hostname} (see ${logfile})"
    return 1
  fi
}

# --- Main Execution Logic (bounded parallelism, mirrors setup_em.sh) ---
active_pids=()
for machine_name in "${machine_list[@]}"; do
  process_host "$machine_name" &
  active_pids+=($!)

  if [ ${#active_pids[@]} -ge "$MAX_PARALLEL" ]; then
    wait -n
    temp_pids=()
    for pid in "${active_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        temp_pids+=("$pid")
      fi
    done
    active_pids=("${temp_pids[@]}")
  fi
done

echo "Waiting for all model-download processes to complete..."
wait
echo
echo "--- All pods processed. Per-host logs in ${logdir}/load-models-*.log ---"
