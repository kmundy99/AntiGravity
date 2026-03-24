# Multi-stage build keeps the final image small
FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.11-slim

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy source
COPY main.py scraper.py power_rating.py matcher.py writer.py ./

# Cloud Run jobs call the container's default CMD.
# The job exits with code 0 on success, non-zero on failure —
# Cloud Scheduler treats non-zero as a failed execution.
CMD ["python", "main.py"]
