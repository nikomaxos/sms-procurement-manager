from fastapi import APIRouter, Depends
from sqlalchemy import text
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter(prefix="/metrics", tags=["Metrics"])

@router.get("/trends")
def trends(d: str, current=Depends(get_current_user)):
    # Return top-10 networks by count of offers (dummy grouping on existing flat table)
    with engine.begin() as c:
        rows = c.execute(text("""
          SELECT COALESCE(network_name,'(Unknown)') AS name, COUNT(*) AS n
          FROM offers
          WHERE (price_effective_date = :d) OR (created_at::date = :d) OR (updated_at::date = :d)
          GROUP BY 1 ORDER BY 2 DESC LIMIT 10
        """), dict(d=d)).all()
    return {"date": d, "buckets": [{"label": r.name, "value": int(r.n)} for r in rows]}
