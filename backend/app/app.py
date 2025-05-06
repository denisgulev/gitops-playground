from flask import Flask, jsonify, request, redirect
import logging
import watchtower
import os

app = Flask(__name__)

app.logger.handlers = []  # Clear Flask's default handlers
app.logger.propagate = True

# Setup CloudWatch logging
logger = logging.getLogger("flask_app")
logger.setLevel(logging.INFO)

# AWS region and log group from environment variables or defaults
aws_region = os.environ.get("AWS_REGION", "eu-south-1")
log_group = os.environ.get("CLOUDWATCH_LOG_GROUP", "flask-app-logs")

formatter = logging.Formatter(
    fmt="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
cloudwatch_handler = watchtower.CloudWatchLogHandler(
    log_group=log_group
)
cloudwatch_handler.setFormatter(formatter)
logger.addHandler(cloudwatch_handler)

STATIC_SITE_URL = "https://static-website.denisgulev.com"  # Replace with your static site URL

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

@app.route("/api/info-new")
def info_new():
    logger.info("GET /api/info-new called")
    return jsonify(info="This is a NEW info endpoint.")

@app.route("/api/status")
def status():
    logger.info("GET /api/status called")
    return jsonify(status="App is running")

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