#!/bin/bash
# ════════════════════════════════════════════════════════
# host/foundation.sh - a generic Linux box: a NUC, a tower, a VM
#
# Sourced by seren-prepare-node.sh. Not a Jetson and not a Spark: no CUDA to
# set up, no nvpmodel, no NVMe to claim, and nothing here ever trims an OS -
# a general-purpose box is somebody's general-purpose box. What a host node
# runs is the Seren SERVICES (Memory, Loci, Lodestar...; the service cards),
# and the one thing those need from the box is a Python new enough (3.10+)
# built against an SQLite new enough (3.35+, for ChromaDB).
#
#   01_host_base       curl, jq, ca-certificates
#   02_host_sqlite     SQLite 3.45 into /usr/local   - only when Python is too old
#   03_host_python310  Python 3.10 into /usr/local   - only when Python is too old
#
# WHY THIS EXISTS (5 Oct 2026). The NUC stays on Ubuntu 20.04 because NVIDIA's
# SDK Manager must run on the oldest OS it flashes, and 20.04 ships Python 3.8
# and SQLite 3.31. SerenSystemPrebuilts has carried a focal Python and SQLite
# for that box since May, and node prep had no platform that would fetch them:
# they were unpacked by hand. A box whose own Python is already 3.10+ (22.04,
# 24.04) stages nothing and builds nothing.
#
# Prebuilts come from the *_host-<codename>-<arch> release (focal x86_64 is the
# one that exists). No such release, or a box it does not cover, means a source
# build: ~40 minutes, said before it starts.
# ════════════════════════════════════════════════════════

HOST_PYTHON_VERSION="3.10.14"
HOST_SQLITE_AUTOCONF="sqlite-autoconf-3450100"      # 3.45.1
HOST_SQLITE_YEAR="2024"

# _host_untar TARBALL - unpack a prebuilt into /usr/local whichever way it was
# rooted. build-host-prebuilts.sh roots its tarballs at usr/local/ (unpack at
# /); the Jetson builder roots them inside /usr/local. Read the archive rather
# than assume: a wrong guess leaves /usr/local/usr/local/bin/python3.10.
_host_untar() {
    local tarball="$1"
    if tar tzf "$tarball" 2>/dev/null | grep -qE '^(\./)?usr/local(/|$)'; then
        sudo tar xzf "$tarball" -C /
    else
        sudo tar xzf "$tarball" -C /usr/local
    fi
    sudo ldconfig
}

phase_host_base() {
    if ! command -v apt-get &>/dev/null; then
        info "No apt on this box - install curl and jq yourself if they are missing"
        return 0
    fi
    sudo apt-get install -y curl jq ca-certificates >/dev/null 2>&1 || {
        sudo apt-get update >/dev/null 2>&1
        sudo apt-get install -y curl jq ca-certificates
    }
    log "Base tools present (curl, jq, ca-certificates)"
}

phase_host_sqlite() {
    if seren_host_python_ok; then
        log "SQLite: nothing to install ($(seren_host_python_ok --say))"
        return 0
    fi
    if [ -n "${STAGED_SQLITE_TARBALL:-}" ] && [ -f "$STAGED_SQLITE_TARBALL" ]; then
        log "Installing SQLite from the prebuilt tarball..."
        _host_untar "$STAGED_SQLITE_TARBALL"
        log "SQLite in /usr/local: $(/usr/local/bin/sqlite3 --version 2>/dev/null | awk '{print $1}' || echo '?')"
        return 0
    fi

    log "No SQLite prebuilt for this box - building 3.45 from source (~10 min)"
    sudo apt-get install -y build-essential wget >/dev/null 2>&1 || true
    cd /tmp
    sudo rm -rf "$HOST_SQLITE_AUTOCONF" "$HOST_SQLITE_AUTOCONF.tar.gz" 2>/dev/null || true
    wget -q "https://www.sqlite.org/$HOST_SQLITE_YEAR/$HOST_SQLITE_AUTOCONF.tar.gz"
    tar xzf "$HOST_SQLITE_AUTOCONF.tar.gz"
    cd "$HOST_SQLITE_AUTOCONF"
    CFLAGS="-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_COLUMN_METADATA" ./configure --prefix=/usr/local
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
    cd ~ && sudo rm -rf "/tmp/$HOST_SQLITE_AUTOCONF"*
}

phase_host_python310() {
    if seren_host_python_ok; then
        log "Python: nothing to install ($(seren_host_python_ok --say))"
        _host_say_extensions
        return 0
    fi

    sudo apt-get install -y \
        zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
        libreadline-dev libffi-dev libssl-dev libbz2-dev liblzma-dev >/dev/null 2>&1 || true

    if [ -n "${STAGED_PYTHON_TARBALL:-}" ] && [ -f "$STAGED_PYTHON_TARBALL" ]; then
        log "Installing Python from the prebuilt tarball..."
        _host_untar "$STAGED_PYTHON_TARBALL"
        if command -v python3.10 &>/dev/null; then
            python3.10 -m pip --version &>/dev/null || sudo python3.10 -m ensurepip --upgrade \
                || warn "ensurepip failed on the prebuilt Python"
        fi
        if seren_host_python_ok; then
            log "Python ready: $(seren_host_python_ok --say)"
            _host_say_extensions
            return 0
        fi
        warn "The prebuilt tarball did not yield a usable Python - building from source"
    fi

    log "Building Python $HOST_PYTHON_VERSION from source (~30 min)"
    sudo apt-get install -y build-essential wget >/dev/null 2>&1 || true
    cd /tmp
    sudo rm -rf "Python-$HOST_PYTHON_VERSION" "Python-$HOST_PYTHON_VERSION.tgz" 2>/dev/null || true
    wget -q "https://www.python.org/ftp/python/$HOST_PYTHON_VERSION/Python-$HOST_PYTHON_VERSION.tgz"
    tar xzf "Python-$HOST_PYTHON_VERSION.tgz"
    cd "Python-$HOST_PYTHON_VERSION"
    # Against the SQLite in /usr/local (phase 02), with its path baked in so the
    # interpreter finds it without LD_LIBRARY_PATH; and with loadable SQLite
    # extensions, without which sqlite-vec cannot load and SerenLoci's hybrid
    # finder stays lexical.
    LD_RUN_PATH=/usr/local/lib ./configure --prefix=/usr/local --enable-optimizations \
        --enable-loadable-sqlite-extensions \
        CPPFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib"
    LD_RUN_PATH=/usr/local/lib make -j"$(nproc)"
    sudo make altinstall
    sudo python3.10 -m ensurepip --upgrade
    cd ~ && sudo rm -rf "/tmp/Python-$HOST_PYTHON_VERSION"*
    if seren_host_python_ok; then
        log "Python ready: $(seren_host_python_ok --say)"
        _host_say_extensions
    else
        fail "Python $HOST_PYTHON_VERSION was built and is still not usable - see the log above"
        return 1
    fi
}

# A Python that cannot load SQLite extensions runs every Seren service; only
# Loci's vector search degrades, silently. Say it here, where it can be fixed.
_host_say_extensions() {
    local py; py="$(seren_host_python_ok --which)"
    [ -n "$py" ] || return 0
    if "$py" -c 'import sqlite3,sys; sys.exit(0 if hasattr(sqlite3.connect(":memory:"), "enable_load_extension") else 1)' 2>/dev/null; then
        log "This Python loads SQLite extensions (SerenLoci --vector will work)"
    else
        warn "$py cannot load SQLite extensions: SerenLoci --vector will fall back to lexical search."
        warn "  A Python built with --enable-loadable-sqlite-extensions fixes it (the host prebuilt from Oct 2026 on)."
    fi
}

run_foundation() {
    if [ "${TRIM_OS:-false}" = "true" ] || [ "${WIPE_NVME:-false}" = "true" ]; then
        fail "--trim-os and --wipe-nvme are for dedicated Jetson and Spark nodes."
        fail "  A host box is prepared without removing or formatting anything; drop the flag."
        return 1
    fi
    run_phase "01_host_base"      "Phase 1 - Base tools"   phase_host_base
    run_phase "02_host_sqlite"    "Phase 2 - SQLite"       phase_host_sqlite
    run_phase "03_host_python310" "Phase 3 - Python 3.10+" phase_host_python310
}

# --bootstrap-python: the Python Starwright itself needs, before the TUI.
run_bootstrap_python() {
    run_phase "02_host_sqlite"    "Phase 2 - SQLite"       phase_host_sqlite
    run_phase "03_host_python310" "Phase 3 - Python 3.10+" phase_host_python310
}
