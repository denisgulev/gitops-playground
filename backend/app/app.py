from flask import Flask, jsonify, request, redirect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import logging
import watchtower
import os

# Tempo (distributed tracing) — uncomment when tempo is enabled in observability-stack/docker-compose.yaml
# from opentelemetry import trace
# from opentelemetry.instrumentation.flask import FlaskInstrumentor
# from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
# from opentelemetry.sdk.trace import TracerProvider
# from opentelemetry.sdk.trace.export import BatchSpanProcessor

# AWS region and log group from environment variables or defaults
aws_region = os.environ.get("AWS_REGION", "eu-south-1")
log_group = os.environ.get("CLOUDWATCH_LOG_GROUP", "flask-app-logs")

# Create logger
logger = logging.getLogger("flask_app")
logger.setLevel(logging.INFO)
formatter = logging.Formatter(
    fmt="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)

# Stream Handler (stdout — captured by Docker, shipped by Promtail)
stream_handler = logging.StreamHandler()
stream_handler.setFormatter(formatter)
logger.addHandler(stream_handler)

# CloudWatch Handler
try:
    cloudwatch_handler = watchtower.CloudWatchLogHandler(
        log_group=log_group
    )
    cloudwatch_handler.setFormatter(formatter)
    logger.addHandler(cloudwatch_handler)
except Exception as e:
    logger.warning(f"Could not initialize CloudWatch handler: {e}")

# Use the logger
logger.info("Logging to file + CloudWatch is active.")

# App
app = Flask(__name__)
# FlaskInstrumentor().instrument_app(app)  # Tempo — uncomment when tempo is enabled

# Rate Limiter
limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["200 per day", "50 per hour"],
    storage_uri="memory://"
)

# otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://tempo:4318/v1/traces")  # Tempo — uncomment when tempo is enabled
# trace_provider = TracerProvider()
# trace_provider.add_span_processor(
#     BatchSpanProcessor(OTLPSpanExporter(endpoint=otlp_endpoint))
# )
# trace.set_tracer_provider(trace_provider)

STATIC_SITE_URL = os.environ.get("STATIC_SITE_URL", "https://static-website.example.com")
APP_VERSION = os.environ.get("APP_VERSION", "unknown")

@app.before_request
def log_request_info():
    logger.info(f"Request: {request.method} {request.path} from {request.remote_addr}")

@app.route("/api/hello")
def hello():
    logger.info("GET /api/hello called")
    return jsonify(message="Hello from Flask!")

@app.route("/api/info")
def info():
    logger.info("GET /api/info called")
    return jsonify(info="This is a simple info endpoint.")

@app.route("/api/status")
def status():
    logger.info("GET /api/status called")
    return jsonify(
        status="ok",
        version=APP_VERSION,
        region=aws_region,
        static_site=STATIC_SITE_URL
    )

@app.route("/api/about")
def about():
    logger.info("GET /api/about called")
    return jsonify(
        project="GitOps Playground",
        description="Flask API on EC2, static frontend on S3, served via CloudFront. Fully automated with Terraform and GitHub Actions.",
        stack={
            "frontend": ["S3", "CloudFront", "Route 53", "ACM"],
            "backend": ["EC2", "Docker", "Flask", "Gunicorn", "Nginx"],
            "infrastructure": ["Terraform", "Terraform Cloud"],
            "ci_cd": ["GitHub Actions"],
            "observability": ["Grafana", "Loki", "Promtail", "Tempo"]
        },
        source_code="https://github.com/denisgulev/gitops-playground"
    )

@app.errorhandler(404)
def page_not_found(e):
    logger.warning(f"404 - {request.path} not found")
    return redirect(f"{STATIC_SITE_URL}/error.html", code=302)

@app.errorhandler(Exception)
def handle_exception(e):
    logger.exception(f"Unhandled exception: {e}")
    return jsonify(error="An internal error occurred"), 500

if __name__ == "__main__":
    logger.info("Starting Flask app")
    app.run(host="0.0.0.0", port=8000)