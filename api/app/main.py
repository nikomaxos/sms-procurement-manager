from fastapi import FastAPI
from app.core.database import Base, engine
from app.models import models
from app.routers import users, suppliers, offers

app = FastAPI(title="SMS Procurement Manager", version="0.8.0")
Base.metadata.create_all(bind=engine)

app.include_router(users.router)
app.include_router(suppliers.router)
app.include_router(offers.router)

@app.get("/")
def root():
    return {"message": "Routers and Auth enabled", "version": "0.8.0"}
