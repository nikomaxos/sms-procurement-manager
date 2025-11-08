from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from typing import Any, Dict
from app.core.database import engine
from app.core.auth import get_current_user

router = APIRouter()

def _id_by_name(conn, table, name_field, name_value):
    r = conn.execute(text(f"SELECT id FROM {table} WHERE {name_field}=:v"), {"v": name_value}).first()
    return r[0] if r else None

def _resolve_network(conn, *, network_name=None, mccmnc=None, country_name=None):
    if mccmnc:
        r = conn.execute(text("SELECT id,country_id,mccmnc,name FROM networks WHERE mccmnc=:mm"), {"mm": mccmnc}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name and country_name:
        r = conn.execute(text("""
            SELECT n.id, n.country_id, n.mccmnc FROM networks n
            JOIN countries c ON c.id=n.country_id
            WHERE n.name=:nn AND c.name=:cn
        """), {"nn": network_name, "cn": country_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    if network_name:
        r = conn.execute(text("SELECT id, country_id, mccmnc FROM networks WHERE name=:nn LIMIT 1"),
                         {"nn": network_name}).first()
        if r: return r.id, r.country_id, r.mccmnc
    return None, None, None

def _inherit_charge_model(conn, connection_id):
    r = conn.execute(text("SELECT charge_model FROM supplier_connections WHERE id=:id"), {"id": connection_id}).first()
    return (r[0] if r and r[0] else "Per Submitted")

@router.get("/offers", tags=["Offers"])
def list_offers(
    country_name: str | None = Query(None),
    route_type: str | None = Query(None),
    known_hops: str | None = Query(None),
    supplier_name: str | None = Query(None),
    connection_name: str | None = Query(None),
    sender_id_supported: str | None = Query(None),
    registration_required: str | None = Query(None),
    is_exclusive: str | None = Query(None),
    limit: int = Query(200, ge=1, le=500),
    user=Depends(get_current_user)
):
    q = """
    SELECT oc.id, s.organization_name AS supplier_name,
           sc.connection_name, sc.username AS smsc_username,
           c.name AS country, n.name AS network, n.mccmnc,
           oc.price, oc.previous_price, oc.currency, oc.price_effective_date,
           oc.route_type, oc.known_hops, oc.sender_id_supported,
           oc.registration_required, oc.eta_days, oc.charge_model,
           oc.is_exclusive, oc.notes, oc.updated_by, oc.updated_at
      FROM offers_current oc
      LEFT JOIN supplier_connections sc ON sc.id=oc.connection_id
      LEFT JOIN suppliers s ON s.id=oc.supplier_id
      LEFT JOIN networks n ON n.id=oc.network_id
      LEFT JOIN countries c ON c.id=n.country_id
     WHERE 1=1
    """
    p: Dict[str, Any] = {}
    if country_name: q += " AND c.name=:country"; p["country"]=country_name
    if route_type: q += " AND oc.route_type=:rt"; p["rt"]=route_type
    if known_hops: q += " AND oc.known_hops=:kh"; p["kh"]=known_hops
    if supplier_name: q += " AND s.organization_name ILIKE :sn"; p["sn"]=f"%{supplier_name}%"
    if connection_name: q += " AND sc.connection_name ILIKE :cn"; p["cn"]=f"%{connection_name}%"
    if sender_id_supported:
        q += " AND oc.sender_id_supported @> :sid::jsonb"; p["sid"]=f'["{sender_id_supported}"]'
    if registration_required: q += " AND oc.registration_required=:rr"; p["rr"]=registration_required
    if is_exclusive: q += " AND oc.is_exclusive=:ix"; p["ix"]=is_exclusive
    q += " ORDER BY oc.updated_at DESC LIMIT :lim"; p["lim"]=limit
    with engine.begin() as c:
        rows = c.execute(text(q), p).mappings().all()
    out=[]
    for r in rows:
        d = dict(r)
        if isinstance(d.get("sender_id_supported"), str):
            d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
        out.append(d)
    return out

@router.get("/offers/{oid}", tags=["Offers"])
def get_offer(oid: int, user=Depends(get_current_user)):
    with engine.begin() as c:
        r = c.execute(text("""
            SELECT oc.*, s.organization_name AS supplier_name,
                   sc.connection_name, sc.username AS smsc_username,
                   c.name AS country, n.name AS network, n.mccmnc AS mccmnc_net
              FROM offers_current oc
              LEFT JOIN supplier_connections sc ON sc.id=oc.connection_id
              LEFT JOIN suppliers s ON s.id=oc.supplier_id
              LEFT JOIN networks n ON n.id=oc.network_id
              LEFT JOIN countries c ON c.id=n.country_id
             WHERE oc.id=:id
        """), {"id": oid}).mappings().first()
    if not r: raise HTTPException(404, "Not found")
    d = dict(r); d["mccmnc"] = d.get("mccmnc") or d.get("mccmnc_net")
    if isinstance(d.get("sender_id_supported"), str):
        d["sender_id_supported"] = [x.strip() for x in d["sender_id_supported"].split(",") if x.strip()]
    return d

@router.post("/offers/by_names", tags=["Offers"])
def create_offer_by_names(body: dict, user=Depends(get_current_user)):
    if not body.get("supplier_name") or not body.get("connection_name"):
        raise HTTPException(400, "supplier_name and connection_name required")
    with engine.begin() as c:
        sid = _id_by_name(c, "suppliers", "organization_name", body["supplier_name"])
        if not sid: raise HTTPException(400, "Unknown supplier")
        cid = c.execute(text("""
            SELECT id FROM supplier_connections
             WHERE supplier_id=:sid AND connection_name=:cn
        """), {"sid": sid, "cn": body["connection_name"]}).scalar()
        if not cid: raise HTTPException(400, "Unknown connection for supplier")

        nid, country_id, mm = _resolve_network(
            c,
            network_name=body.get("network_name"),
            mccmnc=body.get("mccmnc"),
            country_name=body.get("country_name")
        )
        if not nid and not mm:
            raise HTTPException(400, "Provide network_name+country_name or mccmnc")

        cm = _inherit_charge_model(c, cid)
        prev = c.execute(text("""
           SELECT price FROM offers_current
            WHERE supplier_id=:s AND connection_id=:c AND COALESCE(network_id,0)=COALESCE(:n,0)
            LIMIT 1
        """), {"s": sid, "c": cid, "n": nid}).scalar()

        r = c.execute(text("""
          INSERT INTO offers_current(
            supplier_id, connection_id, country_id, network_id, mccmnc,
            price, previous_price, currency, price_effective_date,
            route_type, known_hops, sender_id_supported, registration_required,
            eta_days, charge_model, is_exclusive, notes, updated_by, updated_at
          ) VALUES (
            :sid, :cid, :country_id, :nid, :mm,
            :price, :prev, COALESCE(:currency,'EUR'), COALESCE(NULLIF(:eff,''), NOW())::timestamp,
            :rt, :kh, :sid_sup::jsonb, :reg,
            :eta, :cm, :iex, :notes, 'webui', NOW()
          )
          ON CONFLICT (supplier_id, connection_id, network_id)
          DO UPDATE SET
            previous_price = offers_current.price,
            price = EXCLUDED.price,
            currency = EXCLUDED.currency,
            price_effective_date = EXCLUDED.price_effective_date,
            route_type = EXCLUDED.route_type,
            known_hops = EXCLUDED.known_hops,
            sender_id_supported = EXCLUDED.sender_id_supported,
            registration_required = EXCLUDED.registration_required,
            eta_days = EXCLUDED.eta_days,
            charge_model = EXCLUDED.charge_model,
            is_exclusive = EXCLUDED.is_exclusive,
            notes = EXCLUDED.notes,
            mccmnc = EXCLUDED.mccmnc,
            country_id = EXCLUDED.country_id,
            updated_by = 'webui', updated_at = NOW()
          RETURNING id
        """), {
            "sid": sid, "cid": cid, "country_id": country_id, "nid": nid, "mm": mm,
            "price": body.get("price"),
            "prev": prev,
            "currency": body.get("currency") or "EUR",
            "eff": body.get("price_effective_date") or "",
            "rt": body.get("route_type"),
            "kh": body.get("known_hops"),
            "sid_sup": body.get("sender_id_supported") or [],
            "reg": body.get("registration_required"),
            "eta": body.get("eta_days"),
            "cm": cm,
            "iex": body.get("is_exclusive"),
            "notes": body.get("notes")
        }).first()
    return {"id": r[0]}

@router.patch("/offers/{oid}", tags=["Offers"])
def patch_offer(oid: int, body: dict, user=Depends(get_current_user)):
    sets, p = [], {"id": oid}
    # network resolution
    nid, country_id, mm = None, None, None
    with engine.begin() as c:
        if body.get("mccmnc") or body.get("network_name") or body.get("country_name"):
            nid, country_id, mm = _resolve_network(c,
                network_name=body.get("network_name"),
                mccmnc=body.get("mccmnc"),
                country_name=body.get("country_name"))
    if nid: sets += ["network_id=:nid"]; p["nid"]=nid
    if country_id: sets += ["country_id=:cid"]; p["cid"]=country_id
    if mm: sets += ["mccmnc=:mm"]; p["mm"]=mm

    simple = {
        "price": "price", "price_effective_date":"price_effective_date",
        "route_type":"route_type", "known_hops":"known_hops",
        "registration_required":"registration_required",
        "eta_days":"eta_days", "is_exclusive":"is_exclusive",
        "notes":"notes", "currency":"currency"
    }
    for k, col in simple.items():
        if k in body:
            sets.append(f"{col} = :{k}")
            p[k] = body[k]
    if "sender_id_supported" in body:
        sets.append("sender_id_supported = :sid::jsonb")
        p["sid"] = body["sender_id_supported"]

    # previous_price if price changes
    with engine.begin() as c:
        cur = c.execute(text("SELECT price FROM offers_current WHERE id=:id"), {"id": oid}).scalar()
    if "price" in p and cur is not None and p["price"] != cur:
        sets.append("previous_price = :cur")
        p["cur"] = cur

    if not sets:
        return {"ok": True}
    q = "UPDATE offers_current SET " + ", ".join(sets) + ", updated_by='webui', updated_at=NOW() WHERE id=:id"
    with engine.begin() as c:
        c.execute(text(q), p)
    return {"ok": True}
