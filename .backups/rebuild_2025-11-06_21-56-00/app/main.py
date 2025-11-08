from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse
import importlib, pkgutil, sys

app = FastAPI(title="SMS Procurement Manager API")

# --- ALWAYS-CORS ---
try:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["*"],
    )
except Exception:
    pass

@app.middleware("http")
async def _always_cors(request: Request, call_next):
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        resp = await call_next(request)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp
# --- END ALWAYS-CORS ---


# --- ALWAYS-CORS (idempotent) ---
try:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["*"],
    )
except Exception:
    pass

@app.middleware("http")
async def _always_cors(request: Request, call_next):
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        resp = await call_next(request)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp
# --- END ALWAYS-CORS ---


# Standard CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

# Unconditional CORS headers for ALL responses (incl. errors & preflight)
@app.middleware("http")
async def _always_cors(request: Request, call_next):
    # Handle preflight for ANY path
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        resp = await call_next(request)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp

# Mount users router explicitly
try:
    from app.routers import users as _users
    app.include_router(_users.router)
except Exception as e:
    print("WARNING: users router failed to mount:", repr(e), file=sys.stderr)

# Auto-include other routers exposing `router`
try:
    import app.routers as _rpk
    for _m in pkgutil.iter_modules(_rpk.__path__):
        if _m.name == "users":
            continue
        try:
            _mod = importlib.import_module(f"app.routers.{_m.name}")
            if hasattr(_mod, "router"):
                app.include_router(_mod.router)
        except Exception as _e:
            print(f"Skipping router {_m.name}: {_e!r}", file=sys.stderr)
except Exception as e:
    print("Router autodiscovery failed:", repr(e), file=sys.stderr)

@app.get("/health")
def health():
    return {"ok": True}
from app.routers import stubs as _stubs
app.include_router(_stubs.router)
