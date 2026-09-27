#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/llama.sh - Install llama.cpp inference server (Xavier)
#
# Sourced by seren-prepare-node.sh. The work is shared (seren_install_llama in
# lib/common.sh): the staged binary into ~/llama.cpp/build/bin/, start/stop
# scripts, ~/seren-llama.env and the Observatory manifest.
#
# Expects $STAGED_LLAMA_BIN set by prebuilts.sh or build.sh. Service phases
# ALWAYS run when explicitly flagged (no phase tracking), so re-running
# re-stages the binary - and keeps ~/seren-llama.env, which is the user's.
#
# Default sizing: 8k context, one slot. Edit ~/seren-llama.env to change it.
# ══════════════════════════════════════════════════════════════

install_llama() {
    seren_install_llama 8192 1
}
