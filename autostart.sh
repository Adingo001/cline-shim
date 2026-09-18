#!/usr/bin/env bash
# Keep the Cline shim listening for as long as this process lives.
#
# Two things have to happen at once, and they are why this is a loop rather
# than a one-shot start:
#
#   1. the shim has to be running -- dsh reaches it at 127.0.0.1:8788 and has
#      no fallback, so a dead shim is a dead editor;
#   2. the WSL2 VM has to stay up. WSL2 tears the VM down once no wsl.exe
#      client is attached, and that takes the shim with it.
#
# systemd owns this process (cline-shim.service, Restart=always), so it outlives
# every shell a user opens and comes back within seconds if it dies.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/ctl.sh" start

while true; do
    sleep 30
    # Idempotent: ctl.sh returns early while the port is still bound, and
    # restarts the shim when it is not.
    "$DIR/ctl.sh" start >/dev/null 2>&1
done