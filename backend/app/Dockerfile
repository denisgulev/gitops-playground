# Use an official Python base image
FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV AWS_DEFAULT_REGION=eu-south-1

# Create non-root user
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Create working directory
WORKDIR /app

# Copy and install pinned dependencies first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app code into container
COPY app.py .

# Create log directory and assign ownership to non-root user
RUN mkdir -p /var/log/flask && chown -R appuser:appgroup /var/log/flask /app

# Switch to non-root user
USER appuser

# Expose the port the app will run on
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/status')"

# Run with gunicorn for production
CMD ["gunicorn", "--workers", "3", "--bind", "0.0.0.0:8000", "app:app"]