import importlib, os, pkgutil
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse

app = FastAPI(title="SMS Procurement Manager (clean)")

# CORS on every response including preflight & errors
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

@app.middleware("http")
async def always_cors(request: Request, call_next):
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

# Mount routers explicitly to avoid accidental duplicates/skip logic
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.metrics import router as metrics_router
from app.routers.networks import router as networks_router
from app.routers.parsers import router as parsers_router
from app.routers.offers import router as offers_router
from app.routers.health import router as health_router

app.include_router(users_router)
app.include_router(conf_router)
app.include_router(settings_router)
app.include_router(metrics_router)
app.include_router(networks_router)
app.include_router(parsers_router)
app.include_router(offers_router)
app.include_router(health_router)
