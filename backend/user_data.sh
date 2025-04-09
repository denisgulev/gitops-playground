#!/bin/bash
yum update -y
yum install -y python3 python3-pip nginx git

# Export to /etc/environment to be available for all processes and users
echo "AWS_DEFAULT_REGION=${aws_region}" >> /etc/environment

# Reload environment variables
source /etc/environment

# Install Flask
pip3 install flask gunicorn watchtower

# Create Flask App
cat <<EOT > /home/ec2-user/app.py
from flask import Flask, jsonify

import watchtower
import logging
from time import strftime
from flask import request, redirect

app = Flask(__name__)

# Configuring Logger to Use CloudWatch
LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.DEBUG)
console_handler = logging.StreamHandler()
cw_handler = watchtower.CloudWatchLogHandler(log_group='application_template')
LOGGER.addHandler(console_handler)
LOGGER.addHandler(cw_handler)
LOGGER.info("***testing logs***")

@app.after_request
def after_request(response):
    return response

@app.route('/api/hello')
def hello():
    LOGGER.info("Calling /api/hello")
    response = jsonify(message="Hello from Flask behind Nginx!")
    return response

@app.errorhandler(404)
def page_not_found(e):
    LOGGER.warning(f"404 error: {request.path} not found.")
    return redirect('https://static-website.denisgulev.com/error.html', code=302)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOT

# Create systemd service for Flask using Gunicorn (production-grade WSGI)
cat <<EOT > /etc/systemd/system/flaskapp.service
[Unit]
Description=Gunicorn instance to serve Flask app
After=network.target

[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=/home/ec2-user
EnvironmentFile=/etc/environment
ExecStart=/usr/local/bin/gunicorn --workers 3 --bind 0.0.0.0:5000 app:app

[Install]
WantedBy=multi-user.target
EOT

# Start and enable Flask (Gunicorn) service
systemctl daemon-reload
systemctl start flaskapp
systemctl enable flaskapp

# Configure Nginx reverse proxy
cat <<EOT > /etc/nginx/conf.d/flaskapp.conf
server {
    listen 80;
    server_name ${api_domain};

    location / {
        # Explicitly allow OPTIONS method
        limit_except GET POST OPTIONS {
            deny all;
        }

        # Handle OPTIONS requests
        if (\$request_method = 'OPTIONS') {
            access_log /var/log/nginx/options_requests.log;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
            add_header 'Access-Control-Allow-Origin' 'https://static-website.denisgulev.com' always;
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain charset=UTF-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        # CORS headers
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
        add_header 'Access-Control-Allow-Origin' 'https://static-website.denisgulev.com' always;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://localhost:5000;
    }
}
EOT

# Start and enable Nginx
systemctl start nginx
systemctl enable nginx