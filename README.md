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
