# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance
resource "aws_instance" "flask_app" {
  ami                         = "ami-00ffa5b66c55581f9"
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.flask_sg_http.id, aws_security_group.flask_sg_https.id]
  subnet_id                   = aws_subnet.public_subnet_1.id
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true
  key_name                    = "flask-key"


  provisioner "file" {
    content = templatefile("${path.module}/user_data/app.py", {
      static_origin = "https://static-website.${var.domain_name}"
    })
    destination = "/tmp/app.py"
  }

  provisioner "file" {
    source      = "${path.module}/user_data/flaskapp.service"
    destination = "/tmp/flaskapp.service"
  }

  provisioner "file" {
    content = templatefile("${path.module}/user_data/flaskapp.conf", {
      api_domain    = "api.${var.domain_name}",
      static_origin = "https://static-website.${var.domain_name}"
    })
    destination = "/tmp/flaskapp.conf"
  }

  provisioner "file" {
    content = templatefile("${path.module}/user_data/bootstrap.sh", {
      aws_region = var.aws_region
    })
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "bash /tmp/bootstrap.sh"
    ]
  }

  tags = {
    Name = "FlaskAppEC2"
  }
}
