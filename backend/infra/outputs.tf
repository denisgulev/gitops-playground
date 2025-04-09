output "flask_app_public_ip" {
  value       = aws_eip.flask_app_eip.public_ip
  description = "Elastic IP address of the Flask app EC2 instance"
}

output "cloudfront_prefix_list_id" {
  value = data.aws_ec2_managed_prefix_list.cloudfront.id
}
