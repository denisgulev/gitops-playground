#!/bin/bash
set -e

# Constants
APP_DIR="/home/ec2-user"
APP_FILE="${APP_DIR}/app.py"
SERVICE_FILE="/etc/systemd/system/flaskapp.service"
NGINX_CONF="/etc/nginx/conf.d/flaskapp.conf"
STATIC_ORIGIN="https://static-website.denisgulev.com"

# System update and package installation
yum update -y
yum install -y python3 python3-pip nginx git

# Set AWS region for all processes
echo "AWS_DEFAULT_REGION=${aws_region}" >> /etc/environment
source /etc/environment

# Install Python packages
pip3 install flask gunicorn watchtower

# Create Flask App
cat > "$APP_FILE" <<EOF
from flask import Flask, jsonify, request, redirect
import watchtower, logging

app = Flask(__name__)
LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.DEBUG)
LOGGER.addHandler(logging.StreamHandler())
LOGGER.addHandler(watchtower.CloudWatchLogHandler(log_group='application_template'))

@app.route('/api/hello')
def hello():
    LOGGER.info("Calling /api/hello")
    return jsonify(message="Hello from Flask behind Nginx!")

@app.errorhandler(404)
def page_not_found(e):
    LOGGER.warning(f"404 error: {request.path} not found.")
    return redirect('${STATIC_ORIGIN}/error.html', code=302)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

# Create Flask systemd service
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gunicorn instance to serve Flask app
After=network.target

[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=${APP_DIR}
EnvironmentFile=/etc/environment
ExecStart=/usr/local/bin/gunicorn --workers 3 --bind 0.0.0.0:5000 app:app

[Install]
WantedBy=multi-user.target
EOF

# Enable Flask service
systemctl daemon-reload
systemctl enable --now flaskapp

# Configure Nginx reverse proxy
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${api_domain};

    location / {
        limit_except GET POST OPTIONS { deny all; }

        if (\$request_method = 'OPTIONS') {
            access_log /var/log/nginx/options_requests.log;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
            add_header 'Access-Control-Allow-Origin' '${STATIC_ORIGIN}' always;
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain charset=UTF-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
        add_header 'Access-Control-Allow-Origin' '${STATIC_ORIGIN}' always;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://localhost:5000;
    }
}
EOF

# Enable Nginx
systemctl enable --now nginx