#!/bin/bash
set -e

# Update and install packages
yum update -y
yum install -y python3 python3-pip nginx git

# Set AWS region
echo "AWS_DEFAULT_REGION=${aws_region}" >> /etc/environment
source /etc/environment

# Install Python dependencies
pip3 install flask gunicorn watchtower

# Move files into place
mv /tmp/app.py /home/ec2-user/app.py
mv /tmp/flaskapp.service /etc/systemd/system/flaskapp.service
mv /tmp/flaskapp.conf /etc/nginx/conf.d/flaskapp.conf

# Setup permissions
chown ec2-user:ec2-user /home/ec2-user/app.py

# Start Flask app service
systemctl daemon-reload
systemctl enable --now flaskapp

# Start Nginx
systemctl enable --now nginx