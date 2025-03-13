output "flask_app_public_ip" {
  value       = aws_eip.flask_app_eip.public_ip
  description = "Elastic IP address of the Flask app EC2 instance"
}

output "ec2_public_dns" {
  value       = aws_instance.flask_app.public_dns
  description = "value of the public DNS of the EC2 instance"
}
