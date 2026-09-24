#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/prebuilts.sh - prebuilt staging for Jetson Orin Nano (jp6)
#
# Sourced by seren-prepare-node.sh when not in --build mode. The staging
# itself lives in lib/common.sh (run_prebuilts_download_foundation /
# run_prebuilts_download_services), driven by the release's SHA256SUMS: names
# come from the archive, every byte is verified before use, and one
# implementation serves every platform. This file exists so the dispatcher's
# "does this platform stage prebuilts" check answers yes; there is nothing
# platform-specific left to say here.
# ══════════════════════════════════════════════════════════════
