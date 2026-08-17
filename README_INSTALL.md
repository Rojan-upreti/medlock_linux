# MedLock install guide

Fully local ChatGPT-style clinical assistant plus an admin control hub for Dell Pro Max with GB10 (NVIDIA DGX Spark) and generic Ubuntu 22.04 / 24.04 NVIDIA boxes. Also runs CPU-only (small GGUF).

Cloud LLM inference is **disabled in config** and `run.sh` will refuse to start if it is enabled.

```
  MedLock.desktop / MedLock.sh  →  Chromium --app= window (UI only)
     |
     v  (servers already running via systemd)
  MedLock FastAPI  ------------------>  PostgreSQL (audit + RAG)
  127.0.0.1:8000   -- /v1/chat/... -->  llama-server 127.0.0.1:8081
                                            |
                                            v
                                         local GGUF

  User data:  the folder you chose at install   (sqlite, uploads, logs)
  Install:    that same folder                  (code, venv, GGUF, .env)
```

Weights are **not** committed to git. The default bundled model is **Qwen2.5 0.5B Instruct Q4_K_M** (~400 MB) at `llm/qwen2.5-0.5b/`. If that file is present, install uses it automatically. Otherwise `./install.sh --download-models` fetches it. Upload MedGemma / Gemma 4 from the admin hub when you have more RAM.

## Frozen `.tar.gz` installer

This live tree can keep changing. To snapshot **code + GGUF + embeddings + venv + llama.cpp** into a file that will not change:

```bash
./scripts/pack_installer.sh
```

Writes (default `~/Desktop`):

- `nvdiahackathon.tar.gz`
- `nvdiahackathon.gz` (alias)
- `install`

Install from that pair (does **not** unpack over `~/Desktop/nvdiahackathon`):

```bash
cd ~/Desktop
./install nvdiahackathon.tar.gz
```

or `./install nvdiahackathon.gz`. A Browse dialog asks where MedLock should live; **everything** (app, `.venv`, models, chats, logs) goes in that folder. Extra flags are forwarded (`./install nvdiahackathon.tar.gz --keep-data`). Skip the dialog with `--dest PATH`. The archive omits `.env`, `.git`, `.venv`, chats, uploads, and logs.

## One-command standard installation

From this folder:

```bash
chmod +x start.sh install.sh MedLock.sh run.sh verify_install.sh uninstall.sh scripts/*.sh
./install.sh --fresh
```

That installs anything missing (venv, llama.cpp, bundled Qwen GGUF, Python deps), asks for **one workspace name** and **where to store files** (Browse…), writes a **Desktop shortcut**, enables the **background user service**, then **opens the UI**. Closing the window leaves MedLock running.

Same thing: `./install.sh` (opens the UI by default). Install only: `./install.sh --no-start`.

A second `./install.sh` on the same account is a **replace**: type `REINSTALL`, or run `./install.sh --fresh`. That wipes previous chats. Use `--keep-data` or `--repair` to keep chats.

Optional: `./start.sh --with-hosts` maps `medlock.chat` / `medlock.admin` (asks for sudo). `./start.sh --with-nemoclaw` onboards OpenClaw after the LLM is healthy.

## Desktop app and workspaces

Preferred launchers:

| How | What happens |
|---|---|
| Desktop **MedLock** icon | Opens the UI. Starts the background service if needed. Closing the window does not stop servers. |
| `./MedLock.sh` | same |
| `./start.sh` | install if needed, then `MedLock.sh` |
| `./run.sh --demo` | servers in the foreground (Ctrl+C stops them) |

Install pins **one** folder. Frozen `./install archive` puts chats in that same folder (`data/medlock.sqlite`, `data/uploads/`, `logs/`). Running `./install.sh` from a source tree still asks for a separate workspace folder (Browse…, default `~/MedLock/<name>`). Demo RAG playbooks still come from install `data/demo_data/`.

`./install.sh` wipes chats unless you pass `--keep-data` or `--repair`.

Ubuntu may require **Allow Launching** on `~/Desktop/MedLock.desktop` the first time.

Admin: sidebar in the window, or http://127.0.0.1:8000/admin.

Stop the background service:

```bash
systemctl --user stop local-enterprise-agent
```

## Chat attachments

In the composer, use **+** or drag-and-drop. Allowed: pdf, png, jpg, webp, gif, txt, md (max 12 MB). PDF/text is extracted locally (`pypdf`). Images are stored; vision needs `MMPROJ_PATH` (current default Qwen has no mmproj).

## Healthcare without a fine-tune

Demo playbooks under `data/demo_data/` are optional RAG context when Local documents is on. Chat does not inject a system persona.

## Offline / preloaded-model installation

On a machine with internet, prefetch once:

```bash
./install.sh --skip-nemoclaw --no-start
./scripts/prefetch_models.sh
```

Copy the tree (including `llm/qwen2.5-0.5b/*.gguf` and `.venv` if architectures match) to the air-gapped box, then:

```bash
./install.sh --offline --non-interactive --skip-nemoclaw \
  --model-path ./llm/qwen2.5-0.5b/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf \
  --llamacpp-dir "$HOME/llama.cpp"
```

`--offline` refuses Hugging Face, NemoClaw, and git clones. llama.cpp must already be built.

## Verification

```bash
./verify_install.sh
```

Exits nonzero on FAIL. GPU missing is WARN (CPU fallback), not FAIL. Missing `~/MedLock` is WARN until first desktop launch.

Health while running:

```bash
curl -sS http://127.0.0.1:8000/health
```

## Start without the desktop window

```bash
./run.sh --demo
```

Demo mode uses `data/demo_data/` only. ServiceNow stays off unless `SERVICENOW_ENABLED=true` in `.env`. Headless `run.sh` still writes runtime data under `~/MedLock/MedLock` unless `MEDLOCK_DATA` is set.

Dry-run (no processes):

```bash
./run.sh --dry-run
```

Custom bind (still loopback by default):

```bash
./run.sh --host 127.0.0.1 --port 8000
```

## Hostnames (`medlock.chat` / `medlock.admin`)

`./scripts/setup_hosts.sh` asks before sudo and appends:

```
127.0.0.1 medlock.chat medlock.admin # medlock-local-enterprise-agent
```

Port 80 needs extra privileges. Default app port is **8000**, so URLs are `http://medlock.chat:8000` unless you run with `--port 80` as root (not recommended).

## OpenAI-compatible API for internal apps

```bash
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <key from admin hub>" \
  -d '{"model":"medlock-llm","messages":[{"role":"user","content":"Hello"}]}'
```

Create keys in the admin hub. llama.cpp itself listens on `127.0.0.1:8081` with `LLAMA_API_KEY`.

## NemoClaw + OpenShell + OpenClaw

After llama-server is healthy, `run.sh` can download NVIDIA’s installer **to disk first** (never `curl | bash` in one step) and onboard:

```bash
NEMOCLAW_PROVIDER=llama-cpp
# authenticated llama.cpp on 127.0.0.1:8081
```

Skip with `./install.sh --skip-nemoclaw` or `MEDLOCK_SKIP_NEMOCLAW=1` (desktop launch sets this by default). Docker is optional for MedLock; NemoClaw may still want it.

Manual:

```bash
./scripts/setup_nemoclaw.sh
```

## ServiceNow (optional, off by default)

Keep `network.servicenow_enabled: false` and `SERVICENOW_ENABLED=false` unless you have a **sandbox** instance.

High-level OAuth (least privilege):

1. In the sandbox, create an OAuth client for a dedicated integration user.
2. Grant only the tables/APIs the demo needs (no production write roles).
3. Put instance URL, client id, and client secret in `.env` (`chmod 600`).
4. Set `SERVICENOW_ENABLED=true` only after that.
5. `./install.sh --test-servicenow` checks that variables exist; it never prints secret values.

## Hackathon compliance

| Requirement | How MedLock meets it |
|---|---|
| Local LLM | llama.cpp + local GGUF, `inference.mode: local` |
| Local embeddings | fastembed / lexical fallback, `embeddings.mode: local` |
| Local RAG | workspace `data/documents` + install `data/demo_data` + Postgres/SQLite chunks |
| No cloud inference | `allow_cloud_llm: false`; `run.sh` hard-refuses otherwise |
| OpenClaw stack | Optional NemoClaw onboard to local `:8081` |
| User data isolation | Named workspaces under `~/MedLock/<name>/` |

## systemd (default)

Install enables a user unit so llama-server + FastAPI stay up after you close the window or terminal. Runtime data is `$MEDLOCK_DATA` from `.env` (`~/MedLock/<workspace>`).

```bash
systemctl --user status local-enterprise-agent
systemctl --user start local-enterprise-agent
systemctl --user stop local-enterprise-agent
journalctl --user -u local-enterprise-agent -f
```

Opt out: `./install.sh --without-systemd`. After reboot, log in once, or run `loginctl enable-linger $USER` so the service can start without a graphical session.

`./MedLock.sh` only opens the UI if the service (or `/health`) is already up.

## Troubleshooting

**GPU unavailable / missing CUDA**  
`scripts/check_gpu.py` should WARN, not abort. Rebuild llama.cpp CPU-only or with `-DCMAKE_CUDA_ARCHITECTURES=121` on GB10. On Spark, ignore nvidia-smi VRAM; use `free -h`.

**Python failure**  
Need 3.10+. Prefer 3.11: `sudo apt-get install -y python3.11 python3.11-venv python3.11-dev` then `./install.sh --repair`. Optional better RAG: `.venv/bin/pip install -r requirements-embeddings.txt`.

**Desktop window did not open**  
The launcher tries Chromium/Chrome `--app=` first, then pywebview, then the system browser. Closing that window does not stop the service. Open http://127.0.0.1:8000/ if no window appears.

**Port occupied**  
`ss -ltnp | grep -E '8000|8081'`. Change `--port` / `LLAMA_PORT` in `.env`.

**Permissions**  
`.env` must be `600`. Workspace dirs under `~/MedLock` must be writable. Installer never silent-sudos.

**Model not found**  
Put a `.gguf` in `llm/`, or `--model-path`, or upload in admin. Validate: `python3 scripts/check_models.py --model-path FILE --pretty`.

**Postgres refused / SQLite fallback**  
If port 5432 is closed, the app uses `$MEDLOCK_DATA/data/medlock.sqlite` with WAL and a busy timeout.

**ServiceNow OAuth failure**  
Confirm sandbox URL, client id/secret, redirect/callback if any, and that `SERVICENOW_ENABLED` is actually true. `verify_install.sh` only checks presence, not a live token, and never prints secrets.

**NemoClaw onboard fails**  
Confirm `curl http://127.0.0.1:8081/health` and `/v1/models` with the bearer token. Fallback provider is MedLock `http://127.0.0.1:8000/v1`.

## Uninstall

```bash
./uninstall.sh                     # stop unit/pids only; keep data
./uninstall.sh --remove-venv --remove-systemd --remove-cache
./uninstall.sh --remove-models     # extra flag; GGUFs otherwise kept
./uninstall.sh --purge             # type DELETE; destroys .env and leftover install sqlite
./uninstall.sh --purge-workspaces  # type DELETE; destroys ~/MedLock and the desktop icon
```

Does not uninstall OS packages or the llama.cpp tree under `--llamacpp-dir`.

## Layout

```
[PROJECT_DIR]                 install tree (code + models)
   ├── app/                      FastAPI + chat/admin UI + desktop/workspace
   ├── MedLock.sh                desktop launcher
   ├── packaging/MedLock.desktop shortcut template
   ├── config/local.yaml         generated; cloud LLM forced off
   ├── data/demo_data            synthetic clinical playbooks
   ├── data/documents            RAG corpus
   ├── data/uploads/             chats attachments (self-contained install)
   ├── data/medlock.sqlite       chats (self-contained install)
   ├── db/schema.sql             Postgres audit + RAG
   ├── llm/                      bundled Qwen 0.5B GGUF (default); optional extra GGUFs
   ├── llama.cpp/                local llama-server (self-contained install)
   ├── models/                   embeddings cache
   ├── logs/                     app + systemd logs
   ├── scripts/                  installer helpers
   ├── systemd/                  user unit template (headless)
   └── .venv/

~/MedLock/<workspace>/        only used if you run ./install.sh without --self-contained
├── data/medlock.sqlite
├── data/uploads/
├── data/documents/
└── logs/
```

## Flags (installer)

```
./install.sh --project-dir PATH --model-dir PATH --model-path PATH \
  --llamacpp-dir PATH --download-models --non-interactive --offline \
  --with-systemd --without-systemd --test-servicenow --repair --yes \
  --skip-nemoclaw --keep-data --fresh --self-contained --workspace NAME --data-dir PATH --help
```

`--fresh` wipes chats and re-asks the workspace name and data folder (no `REINSTALL` prompt). `--workspace` and `--data-dir` skip those prompts.
