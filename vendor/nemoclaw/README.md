# Local NemoClaw / OpenShell / OpenClaw

NVIDIA CLIs live in this folder so MedLock does not call the internet at install or start.

```
vendor/nemoclaw/
  installer/nemoclaw.sh     # saved NVIDIA bootstrap (never curl | bash)
  bin/openshell
  bin/openshell-gateway
  bin/openshell-sandbox
  bin/openshell-driver-vm   # KVM MicroVM driver (used when Docker is absent)
  bin/nemoclaw              # host CLI (NVIDIA npm package, or MedLock shim)
  bin/openclaw              # host CLI (sandbox agent, or MedLock shim)
```

One-time fetch (needs network):

```bash
./scripts/fetch_nemoclaw.sh
```

After that, `./install.sh` onboards from here and `./MedLock.sh` starts the sandbox. Inference stays on this machine’s llama-server (`127.0.0.1:8081`).

OpenShell sandboxes need a compute driver. Docker is used when it is installed and running. Otherwise the gateway uses the local **KVM VM driver** (`openshell-driver-vm`). No GPU is required. Chat still works if the sandbox image download is slow or fails.
