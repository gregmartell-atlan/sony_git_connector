"""HTTP wrapper so the wiki -> glossary sync can run on AWS App Runner.

GET  /health  -> 200 (App Runner health check, no auth)
POST /sync    -> starts a sync in the background, 202 (needs X-Sync-Token)
GET  /status  -> last run result (needs X-Sync-Token)

Env vars (secrets come from Secrets Manager via App Runner):
  ATLAN_API_KEY, GITHUB_TOKEN, SYNC_TOKEN  required
  ATLAN_BASE_URL (default https://dsm.atlan.com), GITHUB_REPO, GLOSSARY_NAME
"""

from __future__ import annotations

import asyncio
import hmac
import os
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException

from app.contracts import GlossarySyncConfig
from app.glossary_sync import sync_wiki_to_glossary
from pyatlan_v9.client.atlan import AtlanClient

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

_lock = asyncio.Lock()
_last: dict = {"state": "never_run"}


def _auth(token: Optional[str]) -> None:
    expected = os.environ.get("SYNC_TOKEN", "")
    if not expected or not token or not hmac.compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="unauthorized")


async def _run(dry_run: bool, phase1: bool) -> None:
    global _last
    _last = {"state": "running"}
    try:
        cfg = GlossarySyncConfig(
            repo_full_name=os.environ.get("GITHUB_REPO", "sony-telemetry/schema-registry"),
            github_token=os.environ["GITHUB_TOKEN"],
            glossary_name=os.environ.get("GLOSSARY_NAME", "sony_telemetry"),
            phase1_filter=phase1,
            dry_run=dry_run,
        )
        client = AtlanClient(
            base_url=os.environ.get("ATLAN_BASE_URL", "https://dsm.atlan.com"),
            api_key=os.environ["ATLAN_API_KEY"],
        )
        result = await sync_wiki_to_glossary(cfg, client)
        _last = {"state": "done", "result": result.model_dump()}
    except Exception:
        # Generic message to clients; details go to the service log.
        import logging

        logging.getLogger("sync").exception("sync failed")
        _last = {"state": "failed"}
    finally:
        _lock.release()


@app.get("/health")
async def health() -> dict:
    return {"ok": True}


@app.post("/sync", status_code=202)
async def sync(
    bg: BackgroundTasks,
    dry_run: bool = False,
    phase1: bool = True,
    x_sync_token: Optional[str] = Header(default=None),
) -> dict:
    _auth(x_sync_token)
    if _lock.locked():
        raise HTTPException(status_code=409, detail="sync already running")
    await _lock.acquire()
    bg.add_task(_run, dry_run, phase1)
    return {"accepted": True, "dry_run": dry_run, "phase1": phase1}


@app.get("/status")
async def status(x_sync_token: Optional[str] = Header(default=None)) -> dict:
    _auth(x_sync_token)
    return _last
