resource "aws_eip" "flask_app_eip" {
  instance = aws_instance.flask_app.id
  domain   = "vpc"

  tags = {
    Name = "FlaskAppElasticIP"
  }
}
