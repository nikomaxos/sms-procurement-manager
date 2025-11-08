from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import PlainTextResponse
from sqlalchemy import select

from app.core.database import Base, engine, SessionLocal
from app.models.user import User
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.metrics import router as metrics_router
from app.routers.networks import router as networks_router
from app.routers.parsers import router as parsers_router
from app.routers.offers import router as offers_router
from app.routers.health import router as health_router

app = FastAPI(title="SMS Procurement Manager (final)")

# Global CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

# Ensure CORS even on errors and preflight
@app.middleware("http")
async def always_cors(request: Request, call_next):
    if request.method.upper() == "OPTIONS":
        resp = PlainTextResponse("", status_code=204)
    else:
        try:
            resp = await call_next(request)
        except Exception as e:
            # return plain 500 but keep CORS so the browser can see it
            resp = PlainTextResponse("Internal Server Error", status_code=500)
    origin = request.headers.get("origin") or "*"
    req_headers = request.headers.get("access-control-request-headers") or "*"
    resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Credentials"] = "false"
    resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = req_headers
    resp.headers["Access-Control-Expose-Headers"] = "*"
    return resp

@app.on_event("startup")
def init_db_and_admin():
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        admin = db.execute(select(User).where(User.username=="admin")).scalar_one_or_none()
        if not admin:
            db.add(User(username="admin", password_hash="$2b$12$V83kM0xwP2YV3YFZJmG3zOZ2oG3jv8x3wYtQz6s9aYk3rCz9ZQH2G", role="admin"))  # bcrypt for "admin123"
            db.commit()

# routers
app.include_router(users_router)
app.include_router(conf_router)
app.include_router(settings_router)
app.include_router(metrics_router)
app.include_router(networks_router)
app.include_router(parsers_router)
app.include_router(offers_router)
app.include_router(health_router)
