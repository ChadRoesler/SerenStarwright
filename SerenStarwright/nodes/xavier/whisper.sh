#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/whisper.sh - whisper.cpp speech to text (xavier)
#
# The work is shared (seren_install_whisper in lib/common.sh); what differs
# per platform is the default model: the Xavier has room for small.en (~470MB): better accuracy, still real-time.
# --whisper-model overrides it.
# ══════════════════════════════════════════════════════════════

install_whisper() {
    seren_install_whisper "small.en"
}
