#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/chroma.sh — Install ChromaDB vector store (DGX Spark)
#
# Ubuntu 24.04 ships SQLite 3.40+ — well above ChromaDB's 3.35 minimum.
# No source build needed. Spark has 128GB, so persistence dir can be
# generous.
# ══════════════════════════════════════════════════════════════

install_chroma() {
    local USER_HOME="/home/$TARGET_USER"

    # Sanity check — Ubuntu 24.04 should have 3.40+
    local SQLITE_VERSION
    SQLITE_VERSION=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || echo "0")
    local REQUIRED="3.35.0"
    local LOWEST
    LOWEST=$(printf '%s\n%s\n' "$REQUIRED" "$SQLITE_VERSION" | sort -V | head -n1)
    if [ "$LOWEST" != "$REQUIRED" ]; then
        warn "SQLite $SQLITE_VERSION is older than expected for Ubuntu 24.04 (need >= $REQUIRED)"
        warn "ChromaDB may fail. Investigate why apt has an old sqlite3."
    else
        log "SQLite $SQLITE_VERSION ✓"
    fi

    ensure_venv chroma

    log "Installing chromadb into venv..."
    venv_pip chroma install chromadb || {
        fail "ChromaDB install failed"
        return 1
    }

    sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/seren-memory"

    venv_python chroma -c "
import chromadb
client = chromadb.PersistentClient(path='$USER_HOME/seren-memory')
print(f'  chromadb {chromadb.__version__} imports OK')
print(f'  persistence dir: $USER_HOME/seren-memory')
" 2>&1 || warn "chromadb import failed"

    log "ChromaDB installed; persistence at $USER_HOME/seren-memory"
    log "Venv: ~/seren-venvs/chroma"
}
