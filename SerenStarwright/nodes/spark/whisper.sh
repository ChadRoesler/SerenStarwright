#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/whisper.sh - whisper.cpp speech to text (spark)
#
# The work is shared (seren_install_whisper in lib/common.sh); what differs
# per platform is the default model: the Spark has the memory for large-v3-turbo (~1.6GB), the accurate one.
# --whisper-model overrides it.
# ══════════════════════════════════════════════════════════════

install_whisper() {
    seren_install_whisper "large-v3-turbo"
}
