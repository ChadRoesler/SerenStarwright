#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/chroma.sh — Install ChromaDB vector store (Xavier)
#
# Sourced by seren-setup.sh. Defines install_chroma().
#
# Uses a dedicated venv at ~/seren-venvs/chroma. ChromaDB pulls in
# its own dep tree (fastapi, pydantic, opentelemetry, etc.) that we
# don't want polluting other services.
#
# Requires SQLite >= 3.35 (handled by foundation phase 02).
# ══════════════════════════════════════════════════════════════

install_chroma() {
    local USER_HOME="/home/$TARGET_USER"

    # ── SQLite sanity check (foundation should have handled this) ──
    local SQLITE_VERSION; SQLITE_VERSION=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || echo "0")
    local REQUIRED="3.35.0"
    local LOWEST; LOWEST=$(printf '%s\n%s\n' "$REQUIRED" "$SQLITE_VERSION" | sort -V | head -n1)
    if [ "$LOWEST" != "$REQUIRED" ]; then
        fail "SQLite $SQLITE_VERSION too old for ChromaDB (need >= $REQUIRED)"
        fail "Foundation phase 02 should have built SQLite 3.45 — did it run?"
        return 1
    fi
    log "SQLite $SQLITE_VERSION ✓"

    # ── Venv ──
    ensure_venv chroma

    # ── Install chromadb + pysqlite3-binary ──
    # Python 3.10's `sqlite3` module is statically linked against whatever
    # libsqlite3 was available when CPython was compiled. Our prebuilt Python
    # tarball was compiled before foundation phase 2 installs SQLite 3.45,
    # so the venv's `import sqlite3` returns the older Ubuntu 20.04 version
    # (3.31.x), which ChromaDB rejects.
    #
    # Fix: install pysqlite3-binary (a pip wheel bundling its own libsqlite3
    # 3.45+) and add a sitecustomize.py shim that swaps it in for `sqlite3`
    # before any module loads. This is ChromaDB's officially documented
    # workaround for older Pythons. See:
    #   https://docs.trychroma.com/troubleshooting#sqlite
    log "Installing chromadb + pysqlite3-binary into venv..."
    venv_pip chroma install pysqlite3-binary || \
        warn "pysqlite3-binary install failed — chromadb may reject the system sqlite3"
    venv_pip chroma install chromadb || {
        fail "ChromaDB install failed"
        return 1
    }

    # ── Deploy sqlite3 shim via sitecustomize.py ──
    # Python auto-imports sitecustomize.py at startup if it's on sys.path,
    # so dropping this file in the venv's site-packages makes EVERY python
    # invocation in the chroma venv use pysqlite3 transparently.
    local CHROMA_SITE
    CHROMA_SITE=$(venv_python chroma -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")
    if [ -n "$CHROMA_SITE" ] && [ -d "$CHROMA_SITE" ]; then
        sudo -u "$TARGET_USER" tee "$CHROMA_SITE/sitecustomize.py" > /dev/null << 'EOF'
# Seren chroma venv — swap stdlib sqlite3 for pysqlite3 (which bundles a
# modern libsqlite3 >= 3.45 that ChromaDB requires). This file is auto-
# imported by Python at startup, so the swap happens before any import
# of sqlite3 can return the stale system version.
import sys
try:
    __import__("pysqlite3")
    sys.modules["sqlite3"] = sys.modules.pop("pysqlite3")
except ImportError:
    pass  # fall through to stdlib sqlite3 — chromadb will complain loudly if too old
EOF
        log "sqlite3 shim installed at $CHROMA_SITE/sitecustomize.py"
    else
        warn "Could not locate venv site-packages — sqlite3 shim not installed"
    fi

    # ── Persistence dir ──
    sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/seren-memory"

    # ── Verify in venv ──
    venv_python chroma -c "
import sqlite3
print(f'  sqlite3 version (after shim): {sqlite3.sqlite_version}')
import chromadb
client = chromadb.PersistentClient(path='$USER_HOME/seren-memory')
print(f'  chromadb {chromadb.__version__} imports OK')
print(f'  persistence dir: $USER_HOME/seren-memory')
" 2>&1 || warn "chromadb import failed — check pip install above"

    log "ChromaDB installed; persistence at $USER_HOME/seren-memory"
    log "Venv: ~/seren-venvs/chroma"
}
