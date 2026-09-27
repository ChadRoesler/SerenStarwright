#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/whisper.sh - whisper.cpp speech to text (nano)
#
# The work is shared (seren_install_whisper in lib/common.sh); what differs
# per platform is the default model: an 8GB Orin Nano shares its memory with llama-server; base.en is ~150MB and quick.
# --whisper-model overrides it.
# ══════════════════════════════════════════════════════════════

install_whisper() {
    seren_install_whisper "base.en"
}
