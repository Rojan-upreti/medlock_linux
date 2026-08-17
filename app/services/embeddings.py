from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path
from typing import Sequence

import numpy as np

from app.settings import get_settings

log = logging.getLogger("medlock.embeddings")

_DIM = 384


@lru_cache(maxsize=1)
def _fastembed_model():
    settings = get_settings()
    cache = settings.EMBEDDING_MODEL_PATH or str(settings.PROJECT_DIR / "models" / "embeddings" / "bge-small-en-v1.5")
    Path(cache).mkdir(parents=True, exist_ok=True)
    try:
        from fastembed import TextEmbedding
    except Exception as exc:
        log.warning("fastembed unavailable: %s", exc)
        return None
    try:
        # Prefer local files if present; otherwise fastembed may download (install time only).
        return TextEmbedding(model_name="BAAI/bge-small-en-v1.5", cache_dir=cache)
    except Exception as exc:
        log.warning("could not load embedding model: %s — lexical fallback", exc)
        return None


def embed_texts(texts: Sequence[str]) -> list[list[float]]:
    model = _fastembed_model()
    if model is not None:
        vectors = list(model.embed(list(texts)))
        return [v.tolist() if hasattr(v, "tolist") else list(map(float, v)) for v in vectors]
    return [_hashed_vector(t) for t in texts]


def _hashed_vector(text: str) -> list[float]:
    """Deterministic lexical fallback so RAG still works offline without ONNX."""
    vec = np.zeros(_DIM, dtype=np.float32)
    tokens = [t.lower() for t in text.split() if t]
    if not tokens:
        return vec.tolist()
    for tok in tokens:
        h = abs(hash(tok))
        vec[h % _DIM] += 1.0
        vec[(h // _DIM) % _DIM] += 0.5
    norm = np.linalg.norm(vec) or 1.0
    return (vec / norm).tolist()


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    va = np.asarray(a, dtype=np.float32)
    vb = np.asarray(b, dtype=np.float32)
    denom = float(np.linalg.norm(va) * np.linalg.norm(vb)) or 1e-9
    return float(np.dot(va, vb) / denom)
