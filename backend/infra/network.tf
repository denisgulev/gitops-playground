resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_hostnames = true

  tags = {
    Name = "MainVPC"
  }
}

# PUBLIC SUBNETS

resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet1"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet2"
  }
}

# PRIVATE SUBNETS

resource "aws_subnet" "private_subnet_1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.101.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "PrivateSubnet1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.102.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "PrivateSubnet2"
  }
}

resource "aws_security_group" "flask_sg_http" {
  name        = "flask-sg-http"
  description = "Allow inbound traffic on port 80"
  vpc_id      = aws_vpc.main_vpc.id

  tags = {
    Name = "FlaskSGhttp"
  }
}

resource "aws_security_group" "flask_sg_https" {
  name        = "flask-sg-https"
  description = "Allow inbound traffic on port 443"
  vpc_id      = aws_vpc.main_vpc.id

  tags = {
    Name = "FlaskSGhttps"
  }
}

resource "aws_vpc_security_group_ingress_rule" "sg_ingress_http" {
  security_group_id = aws_security_group.flask_sg_http.id

  from_port      = 80
  to_port        = 80
  ip_protocol    = "tcp"
  prefix_list_id = data.aws_ec2_managed_prefix_list.cloudfront.id
  description    = "FROM THE INTERNET - HTTP"
}

resource "aws_vpc_security_group_ingress_rule" "sg_ingress_https" {
  security_group_id = aws_security_group.flask_sg_https.id

  from_port      = 443
  to_port        = 443
  ip_protocol    = "tcp"
  prefix_list_id = data.aws_ec2_managed_prefix_list.cloudfront.id
  description    = "FROM THE INTERNET - HTTPS"
}

# to be enabled when needed; best use it to allow only a specific IP or a range of IPs
resource "aws_vpc_security_group_ingress_rule" "sg_ingress_ssh" {
  security_group_id = aws_security_group.flask_sg.id

  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  cidr_ipv4   = "0.0.0.0/0"
  description = "SSH Access"
}

resource "aws_vpc_security_group_egress_rule" "sg_egress_http" {
  security_group_id = aws_security_group.flask_sg_http.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
  description = "allow outbound traffic"
}

resource "aws_vpc_security_group_egress_rule" "sg_egress_https" {
  security_group_id = aws_security_group.flask_sg_https.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
  description = "allow outbound traffic"
}


// IGW
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "MainIGW"
  }
}

// RT
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "PublicRouteTable"
  }
}

# Associate Route Table with Public Subnet
resource "aws_route_table_association" "public_subnet_1_assoc" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_subnet_2_assoc" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# Data source to fetch the CloudFront prefix list
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
