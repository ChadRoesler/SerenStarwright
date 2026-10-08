#!/usr/bin/env bash
# ==============================================================================
#  seren-layout.sh - what an install root looks like, for scripts that read it.
#
#  Sourced, never run. Deliberately tiny and side-effect free (no set -e, no
#  colours, no output) so setup-seren-service.sh and seren-register-services.sh
#  can both source it without taking on seren-install-lib.sh. They each used to
#  carry their own copy of install_root_of, kept in step by hand.
#
#  The shape is seren_layout's (seren-install-lib.sh): under a root a service
#  lives in <root>/apps/<svc> with its python in <root>/venvs/<svc>.
# ==============================================================================

# install_root_of APP_DIR VENV_DIR - prints the install root, or nothing.
# Both pointing into the SAME parent is the root; an apps/ and a venvs/ under
# different parents, or anything else, is the old layout. Two named installs on one
# host each run an Observatory, so a unit from one
# must not land in the shared roster where the other lists it.
install_root_of() {
  local app="${1%/}" venv="${2%/}"
  local app_up venv_up
  app_up="$(dirname "$app")"; venv_up="$(dirname "$venv")"
  [[ "$(basename "$app_up")" == "apps" && "$(basename "$venv_up")" == "venvs" ]] || return 0
  [[ "$(dirname "$app_up")" == "$(dirname "$venv_up")" ]] && echo "$(dirname "$app_up")"
  return 0
}
