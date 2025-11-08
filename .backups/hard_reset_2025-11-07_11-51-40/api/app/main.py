from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.core.database import Base, engine
from app.routers.conf import router as conf_router
from app.routers.settings import router as settings_router

app = FastAPI(title="SMS Procurement Manager API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # dev
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health(): return {"ok": True}

# create tables
Base.metadata.create_all(bind=engine)

# routers
app.include_router(conf_router)
app.include_router(settings_router)
