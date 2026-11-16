FROM python:3.14-alpine

COPY --from=ghcr.io/astral-sh/uv:0.13.7 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY loadgen.py dataset.py ./

USER 65534
ENTRYPOINT ["/app/.venv/bin/python", "/app/loadgen.py"]
