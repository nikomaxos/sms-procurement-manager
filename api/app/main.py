from app.routers.networks import router as networks_router
from app.routers.countries import router as countries_router
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routers.users import router as users_router
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router
from app.routers.metrics import router as metrics_router
from app.routers.offers import router as offers_router

app = FastAPI(title="SMS Procurement Manager API")

# Permissive CORS (no cookies used; token goes in Authorization header)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_methods=["*"], allow_headers=["*"], allow_credentials=False
)

@app.get("/health")
def health():
    return {"ok": True}

app.include_router(users_router)
app.include_router(conf_router)
app.include_router(settings_router)
app.include_router(metrics_router)
app.include_router(offers_router)

app.include_router(countries_router)
app.include_router(networks_router)