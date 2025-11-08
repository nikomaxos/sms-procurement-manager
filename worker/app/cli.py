import os, sys, traceback, json
from datetime import datetime, timezone
from sqlalchemy import text
from app.db.db import Base, engine, SessionLocal
from app.models import models
from app.parsers.email_ingest import fetch_messages, extract_attachments, match_template, parse_with_template

def ensure_schema():
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE suppliers ALTER COLUMN per_delivered SET DEFAULT FALSE"))
        conn.execute(text("UPDATE suppliers SET per_delivered=FALSE WHERE per_delivered IS NULL"))

def upsert_offer(db, row, supplier_id, connection_id):
    net = db.query(models.Network).filter(models.Network.mccmnc==row["mccmnc"]).first()
    if not net:
        mcc=row["mccmnc"][:3]
        ctry=db.query(models.Country).filter(models.Country.mcc==mcc).first()
        if not ctry:
            ctry=models.Country(name=f"MCC {mcc}", mcc=mcc); db.add(ctry); db.commit(); db.refresh(ctry)
        net=models.Network(country_id=ctry.id, name=f"Network {row['mccmnc']}", mnc=row["mccmnc"][3:], mccmnc=row["mccmnc"])
        db.add(net); db.commit(); db.refresh(net)

    cur=db.query(models.OfferCurrent).filter(
        models.OfferCurrent.supplier_id==supplier_id,
        models.OfferCurrent.connection_id==connection_id,
        models.OfferCurrent.network_id==net.id
    ).first()

    now=datetime.now(timezone.utc)
    currency=(row.get("currency") or "EUR").upper()
    price=row["price"]

    if cur and cur.price==price and (cur.currency or "EUR")==currency:
        return "identical", cur.id

    if cur:
        hist=models.OfferHistory(previous_id=cur.id, supplier_id=cur.supplier_id,
            connection_id=cur.connection_id, network_id=cur.network_id,
            price=cur.price, effective_date=cur.effective_date, updated_at=now)
        db.add(hist)
        cur.price=price; cur.currency=currency; cur.effective_date=now; cur.updated_at=now
        db.commit()
        return "updated", cur.id
    else:
        cur=models.OfferCurrent(supplier_id=supplier_id, connection_id=connection_id, network_id=net.id,
            price=price, currency=currency, effective_date=now, updated_at=now)
        db.add(cur); db.commit(); db.refresh(cur)
        return "inserted", cur.id

def ingest_once(dryrun=False, limit=10):
    ensure_schema()
    host=os.getenv("IMAP_HOST"); user=os.getenv("IMAP_USER"); pwd=os.getenv("IMAP_PASSWORD")
    folder=os.getenv("IMAP_FOLDER","INBOX"); use_ssl=os.getenv("IMAP_SSL","true").lower()!="false"
    if not (host and user and pwd):
        print("❌ IMAP env missing. Set IMAP_HOST, IMAP_USER, IMAP_PASSWORD", file=sys.stderr)
        return

    db=SessionLocal()
    try:
        tpls=db.query(models.ParsingTemplate).filter(models.ParsingTemplate.enabled==True).all()
        msgs=fetch_messages(host, user, pwd, folder=folder, use_ssl=use_ssl, limit=limit)
        total=inserted=updated=identical=errors=0
        for msg in msgs:
            atts=extract_attachments(msg)
            for t in tpls:
                if not match_template(msg, atts, {"conditions": t.conditions or "{}", "mapping": t.mapping or "{}"}):
                    continue
                rows=parse_with_template(msg, atts, {"mapping": t.mapping or "{}"})
                for r in rows:
                    try:
                        total+=1
                        if dryrun: continue
                        status,_id=upsert_offer(db, r, t.supplier_id, t.connection_id)
                        if status=="inserted": inserted+=1
                        elif status=="updated": updated+=1
                        else: identical+=1
                    except Exception:
                        errors+=1
                        traceback.print_exc()
        if dryrun:
            print(f"DRYRUN ✅ parsed={total}")
        else:
            print(f"✅ done total={total} inserted={inserted} updated={updated} identical={identical} errors={errors}")
    finally:
        db.close()

def list_templates():
    db=SessionLocal()
    try:
        rows=db.query(models.ParsingTemplate).filter(models.ParsingTemplate.enabled==True).all()
        for r in rows:
            print(f"[{r.id}] {r.name} (supplier_id={r.supplier_id}, connection_id={r.connection_id})")
    finally:
        db.close()

def seed_demo():
    ensure_schema()
    db=SessionLocal()
    try:
        s=db.query(models.Supplier).filter(models.Supplier.organization_name=="Infobip").first()
        if not s:
            s=models.Supplier(organization_name="Infobip", per_delivered=False); db.add(s); db.commit(); db.refresh(s)
        c=db.query(models.SupplierConnection).filter(models.SupplierConnection.supplier_id==s.id, models.SupplierConnection.username=="mstatlc").first()
        if not c:
            c=models.SupplierConnection(supplier_id=s.id, connection_name="Infobip Local Bypass", kannel_smsc="Infobip_local", username="mstatlc", charge_model="Per Submitted")
            db.add(c); db.commit(); db.refresh(c)
        import json as _json
        t=db.query(models.ParsingTemplate).filter(models.ParsingTemplate.name=="Infobip basic CSV").first()
        if not t:
            cond=_json.dumps({"from":["offers@infobip.com","sales@infobip.com"],"subject_keywords":["price","rate","offer"]})
            mapping=_json.dumps({"username":["username"],"mcc":["mcc"],"mnc":["mnc"],"mccmnc":["mccmnc"],"price":["price"],"currency":["currency"]})
            t=models.ParsingTemplate(supplier_id=s.id, connection_id=c.id, name="Infobip basic CSV", enabled=True, conditions=cond, mapping=mapping, options=_json.dumps({"default_currency":"EUR"}))
            db.add(t); db.commit()
        print("✅ Demo seed done.")
    finally:
        db.close()

def test_imap():
    host=os.getenv("IMAP_HOST"); user=os.getenv("IMAP_USER"); pwd=os.getenv("IMAP_PASSWORD"); folder=os.getenv("IMAP_FOLDER","INBOX")
    if not (host and user and pwd): print("IMAP env missing."); return
    msgs=fetch_messages(host, user, pwd, folder=folder, use_ssl=os.getenv("IMAP_SSL","true").lower()!="false", limit=5)
    print(f"IMAP OK: {len(msgs)} messages")

if __name__=="__main__":
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["ingest-once","ingest-dryrun","seed-demo","list-templates","test-imap"])
    ap.add_argument("--limit", type=int, default=10)
    a=ap.parse_args()
    if a.cmd=="ingest-once": ingest_once(dryrun=False, limit=a.limit)
    elif a.cmd=="ingest-dryrun": ingest_once(dryrun=True, limit=a.limit)
    elif a.cmd=="seed-demo": seed_demo()
    elif a.cmd=="list-templates": list_templates()
    else: test_imap()
