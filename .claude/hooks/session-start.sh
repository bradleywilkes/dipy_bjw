#!/bin/bash
# Builds DIPY and installs dev tooling so Claude Code on the web sessions
# can run tests, ruff, and pre-commit without a manual setup step.
set -euo pipefail

# Only run inside Claude Code on the web — local sessions handle their own envs.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# DIPY requires Python >= 3.12; container default is 3.11. Repoint both
# the alternatives symlinks and /usr/local/bin/python3 (which shadows
# /usr/bin/python3 on $PATH) at 3.12 so `pip`, `pytest`, etc. all resolve
# to a supported interpreter for the rest of the session.
ln -sf /usr/bin/python3.12 /etc/alternatives/python3
ln -sf /usr/bin/python3.12 /etc/alternatives/python
ln -sf /usr/bin/python3.12 /usr/local/bin/python3
ln -sf /usr/bin/python3.12 /usr/local/bin/python

echo "[session-start] Python: $(python3 --version)"

echo "[session-start] Installing runtime + dev dependencies"
# default.txt is needed up front because --no-build-isolation requires scipy
# (cimported by Cython sources) to already be present in the env at build time.
python3 -m pip install --quiet --break-system-packages \
  -r requirements/default.txt -r requirements/dev.txt

echo "[session-start] Building DIPY in editable mode (Cython compile, ~1-2 min)"
python3 -m pip install --quiet --break-system-packages --no-build-isolation -e .

echo "[session-start] Environment ready."
