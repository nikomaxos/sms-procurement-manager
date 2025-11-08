from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.migrations import migrate_users, ensure_admin
from app.migrations_domain import migrate_domain

app = FastAPI(title="SMS Procurement Manager")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

migrate_users()
ensure_admin()
migrate_domain()

from app.routers import users, conf, suppliers, countries, networks, offers, parsers, metrics
app.include_router(users.router,    prefix="/users",    tags=["Users"])
app.include_router(conf.router,     prefix="/conf",     tags=["Config"])
app.include_router(suppliers.router,prefix="/suppliers",tags=["Suppliers"])
app.include_router(countries.router,prefix="/countries",tags=["Countries"])
app.include_router(networks.router, prefix="/networks", tags=["Networks"])
app.include_router(offers.router,   prefix="/offers",   tags=["Offers"])
app.include_router(parsers.router,  prefix="/parsers",  tags=["Parsers"])
app.include_router(metrics.router,  prefix="/metrics",  tags=["Metrics"])

@app.get("/")
def root():
    return {"ok": True}
