#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/llama.sh - Install llama.cpp inference server (DGX Spark)
#
# Blackwell GB10 GPU (sm_121), 128GB unified memory with ~96GB usable by the
# GPU: room for 70B Q4 / 120B Q3 and two concurrent slots. The staged binary
# is Blackwell-tagged; JP7 ships a matching driver, so no compat shim.
#
# The work is shared (seren_install_llama in lib/common.sh). This used to write
# its own ~/start-llama-spark.sh with the model as $1 - no pid, no stop script,
# invisible to the Observatory. Its sizing is kept as the Spark's
# defaults (32k context, two slots, q8_0 KV cache); the rest is the shared
# ~/start_llama.sh + ~/seren-llama.env, so the Spark is driven like the others.
# ══════════════════════════════════════════════════════════════

install_llama() {
    seren_install_llama 32768 2 "--cache-type-k q8_0 --cache-type-v q8_0"
    if [ -f "/home/$TARGET_USER/start-llama-spark.sh" ]; then
        info "~/start-llama-spark.sh is superseded by ~/start_llama.sh + ~/seren-llama.env."
        info "  Left in place (it may carry your model path); it is not what Lodestar runs."
    fi
}
