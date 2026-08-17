# MedLock clinical FAQ (synthetic, not clinical guidance)

MedLock is a fully local healthcare assistant. Inference uses llama.cpp and a GGUF on this machine. Embeddings and documents stay local. Cloud LLM providers are disabled.

## What it is for
Drafting specialist referrals, SOAP notes, discharge summaries, prior-auth language, and patient education for a licensed clinician to edit. It is not a diagnostic service and not a replacement for a chart or an EHR.

## Privacy
Do not paste real HIPAA-protected health information (PHI) — names, MRNs, dates of birth, or other identifiers — in this demo. Use placeholders. Nothing is sent to a cloud LLM.

## Where to work
Chat: http://127.0.0.1:8000/
Admin: http://127.0.0.1:8000/admin
Internal apps: POST /v1/chat/completions with a local API key.

## Hardware note
On Dell Pro Max with GB10 / DGX Spark, nvidia-smi VRAM may not reflect unified memory. Use free -h / MemAvailable.
