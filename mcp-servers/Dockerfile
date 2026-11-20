FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY pyproject.toml ./
COPY mockservers ./mockservers
RUN pip install . && useradd --uid 10001 --no-create-home mock

USER mock
EXPOSE 8000
# Override per service, e.g. `python -m mockservers.tickets`
CMD ["python", "-m", "mockservers.tickets"]
