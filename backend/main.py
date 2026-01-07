from fastapi import FastAPI, UploadFile, File, Form
from sqlalchemy import create_engine, Column, Integer, String, Float
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import math
import os

# --- 1. CONFIGURAÇÃO DO CLOUDINARY (NOVO) ---
import cloudinary
import cloudinary.uploader

# Suas chaves configuradas:
cloudinary.config( 
  cloud_name = "dxurnkjeq", 
  api_key = "921143126863476", 
  api_secret = "4fP5RCf7YE-moY7nJVhvowKkfDU",
  secure = True
)

# --- CONFIGURAÇÃO DO BANCO DE DADOS (HÍBRIDO) ---
# Tenta pegar o banco da Nuvem (Render)
DATABASE_URL = os.getenv("DATABASE_URL")

# Se não achar (significa que está no seu PC), usa o seu local
if not DATABASE_URL:
    # ⚠️ MANTENHA SUA SENHA AQUI (Seu banco local)
    DATABASE_URL = "postgresql://postgres:admin@localhost/shazam_db"

# Correção obrigatória para o Render (ele usa postgres:// mas o Python quer postgresql://)
if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# --- MODELO DA TABELA ---
class Imovel(Base):
    __tablename__ = "imoveis"
    id = Column(Integer, primary_key=True, index=True)
    titulo = Column(String, index=True)
    latitude = Column(Float)
    longitude = Column(Float)
    azimute = Column(Float)
    caminho_foto = Column(String) # Agora guarda o Link da Internet (https://...)

Base.metadata.create_all(bind=engine)

# --- FUNÇÃO MATEMÁTICA (Haversine) ---
def calcular_distancia_metros(lat1, lon1, lat2, lon2):
    R = 6371000 
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)

    a = math.sin(delta_phi / 2.0)**2 + \
        math.cos(phi1) * math.cos(phi2) * \
        math.sin(delta_lambda / 2.0)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    return R * c 

app = FastAPI()

# --- ROTA 1: SALVAR (AGORA ENVIA PARA O CLOUDINARY) ---
@app.post("/api/v1/imoveis")
async def criar_imovel(
    titulo: str = Form(...), latitude: float = Form(...), 
    longitude: float = Form(...), azimute: float = Form(...),
    foto: UploadFile = File(...)
):
    print(">>> Recebendo foto... enviando para Cloudinary...")
    
    # 1. Envia a foto direto para a nuvem (Cloudinary)
    resultado_upload = cloudinary.uploader.upload(foto.file, folder="shazam_imoveis")
    
    # 2. Pega o Link que o Cloudinary gerou
    link_da_foto = resultado_upload.get("secure_url")
    print(f">>> Foto salva com sucesso: {link_da_foto}")

    # 3. Salva os dados no Banco
    db = SessionLocal()
    novo_imovel = Imovel(
        titulo=titulo, 
        latitude=latitude, 
        longitude=longitude, 
        azimute=azimute, 
        caminho_foto=link_da_foto # <--- Salva o LINK no lugar do caminho do arquivo
    )
    db.add(novo_imovel)
    db.commit()
    db.refresh(novo_imovel)
    db.close()
    
    return {"status": "sucesso", "id": novo_imovel.id, "foto_url": link_da_foto}

# --- ROTA 2: BUSCAR (RETORNA LAT/LON E LINK DA FOTO) ---
@app.get("/api/v1/imoveis/proximos")
def buscar_proximos(lat: float, lon: float):
    db = SessionLocal()
    todos_imoveis = db.query(Imovel).all()
    resultados = []
    
    for imovel in todos_imoveis:
        distancia = calcular_distancia_metros(lat, lon, imovel.latitude, imovel.longitude)
        
        # Raio de busca (2km)
        if distancia < 2000:
            resultados.append({
                "id": imovel.id,
                "titulo": imovel.titulo,
                "latitude": imovel.latitude,
                "longitude": imovel.longitude,
                "distancia_metros": round(distancia, 1), 
                "azimute_imovel": imovel.azimute,
                "foto": imovel.caminho_foto # Entrega o link da foto para o Flutter
            })
            
    db.close()
    return resultados