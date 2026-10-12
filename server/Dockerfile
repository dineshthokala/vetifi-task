# Builds a self-contained image with the signing key material and the seed
# datasets. Everything needed to run the demo is in the image, so
# `docker compose up --build` is genuinely the only setup step.

FROM python:3.12-slim

WORKDIR /srv

# Run as a non-root user. The service writes nothing outside its own database
# volume, so it does not need root.
RUN groupadd --system vetifi \
 && useradd --system --gid vetifi --create-home vetifi

# Dependencies first, so a source change does not invalidate this layer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY keys ./keys
COPY seed ./seed

RUN chown -R vetifi:vetifi /srv
USER vetifi

EXPOSE 8000

# No --reload: this is the production entrypoint.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]