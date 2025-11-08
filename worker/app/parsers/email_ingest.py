import email
from email import policy
from imapclient import IMAPClient
from tenacity import retry, stop_after_attempt, wait_exponential
import json
from app.parsers.excel_parser import read_pricelist_bytes, normalize_columns

def extract_attachments(msg):
    files = []
    if msg.is_multipart():
        for part in msg.walk():
            fn = part.get_filename()
            if fn:
                data = part.get_payload(decode=True)
                if data:
                    files.append((fn, data))
    return files

def _hdr_contains(msg, field, values):
    raw = msg.get(field, "") or ""
    raw = raw if isinstance(raw, str) else str(raw)
    return any(v.lower() in raw.lower() for v in values)

def match_template(msg, attachments, tmpl):
    cond = json.loads(tmpl.get("conditions") or "{}")
    if "from" in cond and not _hdr_contains(msg, "from", cond["from"]): return False
    if "to" in cond and not _hdr_contains(msg, "to", cond["to"]): return False
    if "cc" in cond and not _hdr_contains(msg, "cc", cond["cc"]): return False
    subj = msg.get("subject","") or ""
    if "subject_keywords" in cond and not any(k.lower() in subj.lower() for k in cond["subject_keywords"]): return False
    if "filename_keywords" in cond:
      fnames = [a[0].lower() for a in attachments]
      if not any(any(k.lower() in f for k in cond["filename_keywords"]) for f in fnames): return False
    return True

@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, max=8))
def fetch_messages(host, user, password, folder="INBOX", use_ssl=True, limit=10):
    with IMAPClient(host, ssl=use_ssl) as server:
        server.login(user, password)
        server.select_folder(folder)
        ids = server.search(["NOT","DELETED"])
        ids = ids[-limit:]
        resp = server.fetch(ids, ["RFC822"])
        out=[]
        for uid, data in resp.items():
            msg = email.message_from_bytes(data[b"RFC822"], policy=policy.default)
            out.append(msg)
        return out

def _get(row, names):
    for c in names:
        v = row.get(c)
        if v not in (None,"","nan"):
            return str(v).strip()
    return None

def map_row(row, mapping):
    out={}
    out["username"]=_get(row, mapping.get("username",["username"]))
    mcc=_get(row, mapping.get("mcc",["mcc"])); mnc=_get(row, mapping.get("mnc",["mnc"]))
    mm=_get(row, mapping.get("mccmnc",["mccmnc"]))
    if not mm and mcc and mnc: mm=f"{mcc}{mnc}"
    out["mccmnc"]=mm
    pr=_get(row, mapping.get("price",["price"]))
    if not pr: return None
    pr=pr.replace(",",".")
    try: out["price"]=float(pr)
    except: return None
    out["currency"]=(_get(row, mapping.get("currency",["currency"])) or "EUR").upper()
    out["effective"]=_get(row, mapping.get("effective",["effective","valid_from"]))
    return out if out.get("username") and out.get("mccmnc") else None

def parse_with_template(msg, attachments, tmpl):
    import json as _json
    mapping=_json.loads(tmpl.get("mapping") or "{}")
    rows=[]
    for fn, data in attachments:
        try:
            df = read_pricelist_bytes(data, fn)
            df = normalize_columns(df)
            for _, r in df.iterrows():
                obj = map_row(r.to_dict(), mapping)
                if obj: rows.append(obj)
        except Exception:
            continue
    return rows
