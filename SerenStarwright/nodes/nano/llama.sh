#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/llama.sh - Install llama.cpp inference server (Nano)
#
# The work is shared (seren_install_llama in lib/common.sh): the staged
# orin-tagged binary (arch 87) into ~/llama.cpp/build/bin/, start/stop
# scripts, ~/seren-llama.env and the Observatory manifest. What differs per
# platform is the default sizing: 8GB of unified memory shared with Kokoro
# and whisper, so a 4k context and one slot. Edit ~/seren-llama.env to change it.
# ══════════════════════════════════════════════════════════════

install_llama() {
    seren_install_llama 4096 1
}
