# Use an official Python base image
FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV AWS_DEFAULT_REGION=eu-south-1

# Create working directory
WORKDIR /app

# Copy app code into container
COPY app.py .

# Install Flask
RUN pip install flask watchtower \ 
    opentelemetry-api \
    opentelemetry-sdk \
    opentelemetry-instrumentation-flask \
    opentelemetry-exporter-otlp

# Create log directory for Flask
RUN mkdir -p /var/log/flask

# Expose the port Flask will run on
EXPOSE 8000

# Run the application
CMD ["python", "app.py"]