"""
SRI Facturación Service - Microservicio Multi-Cloud
Aplicación FastAPI para demostración de portabilidad GitOps
"""

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import os
import socket
from datetime import datetime

app = FastAPI(
    title="SRI Facturación Service",
    description="Microservicio de facturación electrónica - Demostración GitOps Multicloud",
    version="1.0.0",
    contact={
        "name": "TFM UNIR - GitOps Multicloud",
        "email": "dev@sri-facturacion.dev"
    }
)

# Middleware CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    """Endpoint raíz"""
    return {
        "message": "SRI Facturación Service API",
        "version": "1.0.0",
        "status": "running"
    }


@app.get("/health")
async def health_check():
    """Health check para Kubernetes liveness probe"""
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "hostname": socket.gethostname()
    }


@app.get("/ready")
async def readiness_check():
    """Readiness check para Kubernetes"""
    return {
        "status": "ready",
        "timestamp": datetime.utcnow().isoformat()
    }


@app.get("/metrics")
async def metrics():
    """Endpoint para Prometheus metrics (básico)"""
    return {
        "requests_total": 0,
        "uptime_seconds": 0
    }


@app.get("/api/v1/version")
async def get_version(request: Request):
    """
    Endpoint clave para demostrar portabilidad multi-cloud.
    Retorna la versión y el cloud provider donde está corriendo.
    """
    cloud_provider = os.getenv("CLOUD_PROVIDER", "unknown")
    cluster_name = os.getenv("CLUSTER_NAME", "unknown")
    
    return {
        "version": "1.0.0",
        "cloud": cloud_provider,
        "cluster": cluster_name,
        "hostname": socket.gethostname(),
        "timestamp": datetime.utcnow().isoformat()
    }


@app.get("/api/v1/info")
async def get_info():
    """Información del entorno de ejecución"""
    return {
        "environment": os.getenv("ENVIRONMENT", "development"),
        "cloud_provider": os.getenv("CLOUD_PROVIDER", "unknown"),
        "region": os.getenv("CLOUD_REGION", "unknown"),
        "python_version": os.sys.version,
        "platform": os.sys.platform
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=5000)
    