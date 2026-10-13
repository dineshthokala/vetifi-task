# Builds a self-contained image with the signing key material and the seed
# datasets, so `docker compose up --build` really is the only setup step.

FROM python:3.12-slim

WORKDIR /srv

# Run as a non-root user. The service writes only to its own data directory.
RUN groupadd --system vetifi \
 && useradd --system --gid vetifi --create-home vetifi

# Dependencies first, so a source change does not invalidate this layer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY keys ./keys
COPY seed ./seed
COPY entrypoint.sh ./entrypoint.sh

# /srv/data holds the generated ADMIN_KEY across restarts.
RUN mkdir -p /srv/data && chown -R vetifi:vetifi /srv
USER vetifi

EXPOSE 8000

ENTRYPOINT ["/bin/sh", "./entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]