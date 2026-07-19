# ============================================
# STAGE 1: Builder
# ============================================
FROM python:3.12-slim as builder

WORKDIR /build

# Instalar dependencias de build
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copiar requirements e instalar dependencias
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ============================================
# STAGE 2: Production
# ============================================
FROM python:3.12-slim

# Labels para trazabilidad
LABEL maintainer="TFM-UNIR-GitOps-Multicloud"
LABEL version="1.0.0"
LABEL description="SRI Facturación Service - Multi-Cloud"

# Variables de entorno
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# Crear usuario no-root (seguridad)
RUN groupadd -r appuser && useradd -r -g appuser -d /home/appuser appuser

WORKDIR /app

# Copiar dependencias del builder
COPY --from=builder /install /usr/local

# Copiar código de aplicación
COPY . .

# Cambiar ownership
RUN chown -R appuser:appuser /app

# Cambiar a usuario no-root
USER appuser

# Exponer puerto
EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1

# Comando de inicio
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000", "--workers", "2"]
