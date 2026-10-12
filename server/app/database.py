"""
Database models and connection handling.
Supports PostgreSQL (production) and SQLite (testing/local fallback).
"""

import os
from datetime import datetime, timezone
from pathlib import Path
from sqlalchemy import (
    Column,
    DateTime,
    Float,
    Integer,
    String,
    Text,
    create_engine,
)
from sqlalchemy.orm import declarative_base, sessionmaker

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    f"sqlite:///{Path(__file__).resolve().parent.parent / 'vetifi_server.db'}"
)

# SQLite specific connect_args for multithreading / concurrency
connect_args = {}
if DATABASE_URL.startswith("sqlite"):
    connect_args = {"check_same_thread": False, "timeout": 30}

engine = create_engine(DATABASE_URL, connect_args=connect_args)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class DatasetVersion(Base):
    __tablename__ = "dataset_versions"

    version = Column(String(32), primary_key=True)
    version_num = Column(Integer, nullable=False, unique=True, index=True)
    base_version = Column(String(32), nullable=True)
    schema_version = Column(Integer, nullable=False, default=2)
    payload_json = Column(Text, nullable=False)  # Full snapshot JSON
    delta_json = Column(Text, nullable=True)     # Delta JSON from base_version if available
    sha256 = Column(String(64), nullable=False)
    signature = Column(String(128), nullable=False)
    idempotency_key = Column(String(128), nullable=True, unique=True, index=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


class CalculationLog(Base):
    __tablename__ = "calculation_logs"

    calc_id = Column(String(64), primary_key=True)  # UUID from client for deduplication
    drug_id = Column(String(64), nullable=False)
    drug_name = Column(String(128), nullable=False)
    species = Column(String(32), nullable=False)
    weight_kg = Column(Float, nullable=False)
    weight_unit = Column(String(16), nullable=False)
    weight_entered = Column(Float, nullable=False)
    dose_min_mg = Column(Float, nullable=False)
    dose_max_mg = Column(Float, nullable=False)
    volume_min_ml = Column(Float, nullable=False)
    volume_max_ml = Column(Float, nullable=False)
    dataset_version = Column(String(32), nullable=False)
    timestamp = Column(String(64), nullable=False)
    dose_rate = Column(Float, nullable=True)
    fluid_rate_ml_hr = Column(Float, nullable=True)
    bag_size_ml = Column(Float, nullable=True)
    ml_to_add = Column(Float, nullable=True)
    bag_duration_hrs = Column(Float, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


def init_db():
    Base.metadata.create_all(bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
