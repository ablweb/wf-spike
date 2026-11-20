#!/bin/bash
# jail.sh DIR CMD...: runs CMD in DIR inside a bubblewrap jail: read-only filesystem, DIR writable, no network, no home
# directory (so no token and no ~/.ssh), the state folder with the tokens hidden wherever it is (WF_STATE may put it outside the
# home directory), private /tmp. Hooks run outside Claude's sandbox; this is their sandbox.
dir=$1; shift
st=${WF_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wf/run}
hide=(); [ -d "$st" ] && hide=(--tmpfs "$st")
exec bwrap --ro-bind / / --tmpfs "$HOME" "${hide[@]}" --tmpfs /tmp --bind "$dir" "$dir" --proc /proc --dev /dev --unshare-all \
  --die-with-parent --chdir "$dir" "$@"
