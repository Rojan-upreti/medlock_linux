# MedLock

Local assistant for the Dell × NVIDIA hackathon. Inference, embeddings, RAG, and audit stay on the box. Cloud LLM inference is locked off.

```bash
./install.sh --fresh
```

That wipes previous chats, asks for a workspace name and data folder (Browse…), starts the background service, then opens the UI. Closing the window does **not** stop MedLock.

Already installed and just want to open it: `./MedLock.sh` or `./start.sh`.

- Chat: http://127.0.0.1:8000/
- Stop: `systemctl --user stop local-enterprise-agent`

You can also click the **MedLock** icon on the Desktop (Allow Launching once on Ubuntu).

See **[README_INSTALL.md](README_INSTALL.md)** for reinstall, NemoClaw, ServiceNow, and uninstall.

## Frozen installer archive

Keep this live folder as the running install. To freeze a copy that will not change when you edit here:

```bash
./scripts/pack_installer.sh
```

That writes `~/Desktop/nvdiahackathon.tar.gz` (also `nvdiahackathon.gz`) and `~/Desktop/install`. On another machine or a clean extract:

```bash
cd ~/Desktop
./install nvdiahackathon.tar.gz
```

or `./install nvdiahackathon.gz`. A Browse dialog asks **where MedLock should live**. That folder gets the app, Python environment, models, chats, and logs. It does not unpack over `~/Desktop/nvdiahackathon` unless you pass `--force`, and it does not reuse that tree's `.venv`. Skip the dialog with `--dest PATH`.
