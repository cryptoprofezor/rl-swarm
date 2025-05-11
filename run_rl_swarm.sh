#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RESET_TEXT="\033[0m"

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

cleanup() {
    echo -e "$GREEN_TEXT>> Shutting down trainer...$RESET_TEXT"
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true
    kill -- -$$ || true
    exit 0
}
trap cleanup EXIT

cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn
EOF

echo -e "$GREEN_TEXT>> Connecting to Testnet...$RESET_TEXT"
CONNECT_TO_TESTNET=true

read -p $'>> Which swarm would you like to join (Math (A) or Math Hard (B))? [A/b] ' ab
eb=${ab:-A}
USE_BIG_SWARM=false
[[ "$ab" =~ [Bb] ]] && USE_BIG_SWARM=true

read -p $'>> How many parameters (in billions)? [0.5, 1.5, 7, 32, 72] ' pc
pc=${pc:-0.5}
PARAM_B=$pc

SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
[ "$USE_BIG_SWARM" = true ] && SWARM_CONTRACT="$BIG_SWARM_CONTRACT"

cd modal-login
if ! command -v yarn > /dev/null 2>&1; then
    echo "Installing yarn..."
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
    sudo apt update && sudo apt install -y yarn
fi
yarn install
yarn dev > /dev/null 2>&1 &
sleep 5
cd ..

echo -e "$GREEN_TEXT>> Waiting for modal userData.json...$RESET_TEXT"
while [ ! -f "modal-login/temp-data/userData.json" ]; do sleep 5; done
ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
echo "ORG_ID: $ORG_ID"

ENV_FILE="$ROOT"/modal-login/.env
sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"

pip install --upgrade pip
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &> /dev/null; then
    pip install -r "$ROOT"/requirements-cpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
else
    pip install -r "$ROOT"/requirements-gpu.txt
    pip install flash-attn --no-build-isolation
    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        0.5 | 1.5 | 7) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
    esac
    GAME="$([ "$USE_BIG_SWARM" = true ] && echo dapo || echo gsm8k)"
fi

echo -e "$GREEN_TEXT>> Run the following command in a new terminal to expose your login UI (Serveo):$RESET_TEXT"
echo -e "$BLUE_TEXT   ssh -R 80:localhost:3000 serveo.net$RESET_TEXT"
echo -e "📌 Open the Serveo URL in your browser to complete login."
echo ""

read -p $'Press Enter after completing login in browser...'

echo -e "$GREEN_TEXT>> Starting swarm job...$RESET_TEXT"
HF_TOKEN=${HF_TOKEN:-""}
if [ -z "$HF_TOKEN" ]; then
    read -p ">> Push to HuggingFace Hub? [y/N] " yn
    if [[ "$yn" =~ [Yy] ]]; then
        read -p "Enter HuggingFace token: " HUGGINGFACE_ACCESS_TOKEN
    else
        HUGGINGFACE_ACCESS_TOKEN="None"
    fi
else
    HUGGINGFACE_ACCESS_TOKEN="$HF_TOKEN"
fi

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
fi

wait

