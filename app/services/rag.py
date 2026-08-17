from __future__ import annotations

import logging
from pathlib import Path

from sqlalchemy.orm import Session

from app.db import Chunk, Document
from app.services.embeddings import cosine, embed_texts
from app.settings import get_settings

log = logging.getLogger("medlock.rag")


def chunk_text(text: str, size: int = 1400, overlap: int = 160) -> list[str]:
    text = text.replace("\r\n", "\n").strip()
    if not text:
        return []
    chunks: list[str] = []
    i = 0
    while i < len(text):
        chunks.append(text[i : i + size])
        i += max(size - overlap, 1)
    return chunks


def ingest_text(
    db: Session,
    text: str,
    *,
    filename: str,
    source_path: str | None = None,
    mime_type: str | None = "text/plain",
    demo: bool = False,
) -> Document:
    parts = chunk_text(text)
    vectors = embed_texts(parts) if parts else []
    doc = Document(
        filename=filename,
        source_path=source_path,
        mime_type=mime_type,
        byte_size=len(text.encode("utf-8")),
        demo=demo,
    )
    db.add(doc)
    db.flush()
    for idx, (part, vec) in enumerate(zip(parts, vectors)):
        db.add(Chunk(document_id=doc.id, chunk_index=idx, content=part, embedding_json=vec))
    db.commit()
    db.refresh(doc)
    log.info("ingested %s (%s chunks)", filename, len(parts))
    return doc


def ingest_file(db: Session, path: Path, demo: bool = False) -> Document:
    raw = path.read_text(encoding="utf-8", errors="replace")
    return ingest_text(
        db,
        raw,
        filename=path.name,
        source_path=str(path),
        mime_type="text/plain",
        demo=demo,
    )


def ingest_directory(db: Session, directory: Path, demo: bool = False) -> int:
    if not directory.is_dir():
        return 0
    paths = [
        path
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path.suffix.lower() in {".md", ".txt", ".rst"}
    ]
    existing = {row.source_path: row for row in db.query(Document).filter(Document.source_path.isnot(None)).all()}
    db.commit()
    count = 0
    for path in paths:
        key = str(path)
        prev = existing.get(key)
        if prev is not None:
            if prev.byte_size == path.stat().st_size:
                continue
            db.delete(prev)
            db.commit()
        ingest_file(db, path, demo=demo)
        count += 1
    return count


def _keyword_score(query: str, text: str) -> float:
    q = {t for t in query.lower().replace("/", " ").split() if len(t) > 2}
    if not q:
        return 0.0
    blob = text.lower()
    hits = sum(1 for t in q if t in blob)
    return hits / max(len(q), 1)


def retrieve(db: Session, query: str, top_k: int = 5) -> list[dict]:
    if db.query(Chunk.id).first() is None:
        return []
    qvec = embed_texts([query])[0]
    rows = db.query(Chunk).all()
    scored: list[tuple[float, Chunk]] = []
    for ch in rows:
        if not ch.embedding_json:
            continue
        lexical = _keyword_score(query, ch.content)
        scored.append((0.65 * cosine(qvec, ch.embedding_json) + 0.35 * lexical, ch))
    scored.sort(key=lambda x: x[0], reverse=True)
    out = []
    for score, ch in scored[:top_k]:
        if score <= 0:
            continue
        out.append(
            {
                "score": round(score, 4),
                "content": ch.content,
                "document_id": ch.document_id,
                "chunk_index": ch.chunk_index,
            }
        )
    return out


def build_rag_prefix(hits: list[dict]) -> str:
    if not hits:
        return ""
    blocks = []
    for i, h in enumerate(hits, 1):
        blocks.append(f"[{i} score={h['score']}]\n{h['content']}")
    return (
        "Local document excerpts that may be relevant. Use them only if they help answer the user.\n\n"
        + "\n\n".join(blocks)
    )


def maybe_bootstrap_demo(db: Session) -> None:
    settings = get_settings()
    demo_dir = settings.PROJECT_DIR / "data" / "demo_data"
    docs_dir = settings.data_dir() / "data" / "documents"
    ingest_directory(db, demo_dir, demo=True)
    if not settings.MEDLOCK_DEMO:
        ingest_directory(db, docs_dir, demo=False)
