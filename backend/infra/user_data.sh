#!/bin/bash
set -e

# System update and package installation
yum update -y
yum install -y python3 python3-pip nginx git docker

# Set AWS region for all processes
echo "AWS_DEFAULT_REGION=${aws_region}" >> /etc/environment
source /etc/environment

# Install Gunicorn
pip3 install gunicorn opentelemetry-api \
            opentelemetry-sdk \
            opentelemetry-instrumentation-flask \
            opentelemetry-exporter-otlp

# Create Flask systemd service
cat > "/etc/systemd/system/flaskapp.service" <<EOF
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
EOF

# Enable Gunicorn service
systemctl daemon-reload
systemctl enable --now flaskapp

# Configure Nginx reverse proxy
cat > "/etc/nginx/conf.d/flaskapp.conf" <<EOF
server {
    listen 80;
    server_name ${api_domain};

    location / {
        limit_except GET POST OPTIONS { deny all; }

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

        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
        add_header 'Access-Control-Allow-Origin' 'https://static-website.denisgulev.com' always;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://localhost:8000;
    }
}
EOF

# Enable Nginx
systemctl enable --now nginx

# Enable Docker
systemctl enable --now docker

# Create log directory for Flask
sudo mkdir -p /var/log/flask
sudo chown ec2-user:ec2-user /var/log/flask