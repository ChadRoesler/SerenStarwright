#!/bin/bash
# ════════════════════════════════════════════════════════
# host/prebuilts.sh - prebuilt staging for a generic Linux box
#
# Sourced by seren-prepare-node.sh when not in --build mode. The staging lives
# in lib/common.sh (run_prebuilts_download_foundation), driven by the release's
# SHA256SUMS like every other platform. A host stages a Python and an SQLite
# tarball, and only when its own Python is too old; there are no service
# prebuilts for a host. This file exists so the dispatcher's "does this
# platform stage prebuilts" check answers yes.
# ════════════════════════════════════════════════════════
