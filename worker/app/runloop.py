import os, time, traceback
from app.cli import ingest_once
REFRESH_MINUTES=int(os.getenv("REFRESH_MINUTES","5"))
LIMIT=int(os.getenv("INGEST_LIMIT","50"))
while True:
    try:
        ingest_once(dryrun=False, limit=LIMIT)
    except Exception:
        traceback.print_exc()
    time.sleep(REFRESH_MINUTES*60)
