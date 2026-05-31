resource "aws_ssm_parameter" "ec2_dns" {
  name  = "/infra/ec2/public_dns"
  type  = "String"
  value = aws_eip.flask_app_eip.public_dns
}
