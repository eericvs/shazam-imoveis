from fastapi import FastAPI, UploadFile, File, Form
from sqlalchemy import create_engine, Column, Integer, String, Float
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import math
import os
import cloudinary
import cloudinary.uploader

# --- CONFIGURAÇÃO DO CLOUDINARY ---
cloudinary.config( 
  cloud_name = "dxurnkjeq", 
  api_key = "921143126863476", 
  api_secret = "4fP5RCf7YE-moY7nJVhvowKkfDU",
  secure = True
)

# --- BANCO DE DADOS ---
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    DATABASE_URL = "postgresql://postgres:admin@localhost/shazam_db"

if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class Imovel(Base):
    __tablename__ = "imoveis"
    id = Column(Integer, primary_key=True, index=True)
    titulo = Column(String, index=True)
    latitude = Column(Float)
    longitude = Column(Float)
    azimute = Column(Float)
    caminho_foto = Column(String)

Base.metadata.create_all(bind=engine)

def calcular_distancia_metros(lat1, lon1, lat2, lon2):
    R = 6371000 
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    a = math.sin(delta_phi / 2.0)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c 

app = FastAPI()

@app.post("/api/v1/imoveis")
async def criar_imovel(
    titulo: str = Form(...), latitude: float = Form(...), 
    longitude: float = Form(...), azimute: float = Form(...),
    foto: UploadFile = File(...)
):
    resultado_upload = cloudinary.uploader.upload(foto.file, folder="shazam_imoveis")
    link_da_foto = resultado_upload.get("secure_url")
    
    db = SessionLocal()
    novo_imovel = Imovel(
        titulo=titulo, latitude=latitude, longitude=longitude, 
        azimute=azimute, caminho_foto=link_da_foto
    )
    db.add(novo_imovel)
    db.commit()
    db.refresh(novo_imovel)
    db.close()
    return {"status": "sucesso", "id": novo_imovel.id, "foto_url": link_da_foto}

# --- ROTA DE BUSCA INTELIGENTE ---
@app.get("/api/v1/imoveis/proximos")
def buscar_proximos(lat: float, lon: float, raio: float = 2000): 
    # O "raio" agora é um parâmetro. Se não for enviado, usa 2000m (2km) como padrão.
    db = SessionLocal()
    todos_imoveis = db.query(Imovel).all()
    resultados = []
    
    for imovel in todos_imoveis:
        distancia = calcular_distancia_metros(lat, lon, imovel.latitude, imovel.longitude)
        
        # Usa o raio dinâmico (pode ser 40m ou 2000m dependendo de quem chamou)
        if distancia < raio:
            resultados.append({
                "id": imovel.id,
                "titulo": imovel.titulo,
                "latitude": imovel.latitude,
                "longitude": imovel.longitude,
                "distancia_metros": round(distancia, 1), 
                "azimute_imovel": imovel.azimute,
                "foto": imovel.caminho_foto
            })
            
    db.close()
    return resultados