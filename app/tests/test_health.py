"""
Tests unitarios para endpoints de health y version
"""

import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_root():
    """Test endpoint raíz"""
    response = client.get("/")
    assert response.status_code == 200
    data = response.json()
    assert "message" in data
    assert data["status"] == "running"


def test_health_check():
    """Test health check"""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    assert "timestamp" in data
    assert "hostname" in data


def test_readiness_check():
    """Test readiness check"""
    response = client.get("/ready")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ready"


def test_version_endpoint():
    """Test endpoint de versión (clave para demo multi-cloud)"""
    response = client.get("/api/v1/version")
    assert response.status_code == 200
    data = response.json()
    assert "version" in data
    assert "cloud" in data
    assert "cluster" in data
    assert "timestamp" in data


def test_info_endpoint():
    """Test endpoint de información"""
    response = client.get("/api/v1/info")
    assert response.status_code == 200
    data = response.json()
    assert "environment" in data
    assert "cloud_provider" in data