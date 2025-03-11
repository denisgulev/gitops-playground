#!/bin/bash
    yum update -y
    yum install -y python3 python3-pip nginx git

    # Export to /etc/environment to be available for all processes and users
    echo "AWS_DEFAULT_REGION=${var.aws_region}" >> /etc/environment

    # Reload environment variables
    source /etc/environment

    # Install Flask
    pip3 install flask gunicorn watchtower

    # Create Flask App
    cat <<EOT > /home/ec2-user/app.py
    from flask import Flask

    import watchtower
    import logging
    from time import strftime
    from flask import request

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
        timestamp = strftime('[%Y-%b-%d %H:%M]')
        LOGGER.error('%s %s %s %s %s %s', timestamp, request.remote_addr, request.method, request.scheme, request.full_path, response.status)
        return response

    @app.route('/')
    def hello():
        return "Hello from Flask behind Nginx!"

    if __name__ == '__main__':
        app.run(host='127.0.0.1', port=5000)
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
    ExecStart=/usr/local/bin/gunicorn --workers 3 --bind 127.0.0.1:5000 app:app

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
        server_name _;

        location / {
            proxy_pass http://127.0.0.1:5000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
    EOT

    # Start and enable Nginx
    systemctl start nginx
    systemctl enable nginx