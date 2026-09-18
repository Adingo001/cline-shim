#!/usr/bin/env bash
# Keep the WSL2 VM alive while an OpenAI4S session is marked active.
#
# WSL2 shuts the VM down once no wsl.exe client is attached to it, which takes
# the shim and the detached daemon with them. This process is owned by a
# Windows scheduled task rather than by the launcher shell, so it survives the
# launcher exiting. It exits as soon as `openai4s.ps1 stop` removes the lock.
set -u
LOCK="$HOME/.openai4s/.keepalive"

# `start` touches the lock just after launching this; give it a moment.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$LOCK" ] && break
    sleep 2
done

while [ -f "$LOCK" ]; do
    sleep 20
done