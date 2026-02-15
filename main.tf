# 1. PROVEEDOR (Norte de Virginia)
provider "aws" {
  region = "us-east-1" 
}

# 2. BUSCADOR DE IMAGEN (Amazon Linux 2023)
data "aws_ami" "latest_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# 3. RED (VPC)
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "mathias-project-vpc" }
}

# 4. PUERTA A INTERNET Y SUBREDES (En 2 zonas distintas para alta disponibilidad)
resource "aws_internet_gateway" "main_gw" {
  vpc_id = aws_vpc.main_vpc.id
  tags   = { Name = "mathias-igw" }
}

resource "aws_subnet" "subnet_1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "mathias-subnet-1" }
}

resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "mathias-subnet-2" }
}

resource "aws_route_table" "main_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_gw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.main_rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.main_rt.id
}

# 5. SEGURIDAD (Abrir puerto 80 para la web)
resource "aws_security_group" "web_sg" {
  name   = "mathias-web-sg-v3"
  vpc_id = aws_vpc.main_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 6. APPLICATION LOAD BALANCER (El "jefe" que reparte el tráfico)
resource "aws_lb" "main_alb" {
  name               = "mathias-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
}

resource "aws_lb_target_group" "main_tg" {
  name     = "mathias-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main_tg.arn
  }
}

# 7. MOLDE DE SERVIDOR (Launch Template)
resource "aws_launch_template" "web_config" {
  name_prefix   = "mathias-lt-"
  image_id      = data.aws_ami.latest_amazon_linux.id
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y httpd
              systemctl start httpd
              systemctl enable httpd
              # Obtener metadatos para mostrar en la web
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
              AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
              echo "<h1>Mathias Cloud Project</h1><p><b>Servidor ID:</b> $ID</p><p><b>Zona:</b> $AZ</p>" > /var/www/html/index.html
              EOF
  )
}

# 8. AUTO SCALING GROUP (Vigilante de las 2 máquinas)
resource "aws_autoscaling_group" "web_asg" {
  desired_capacity    = 2 # <--- Creamos 2 máquinas de una vez
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  target_group_arns   = [aws_lb_target_group.main_tg.arn]

  launch_template {
    id      = aws_launch_template.web_config.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Mathias-ASG-Server"
    propagate_at_launch = true
  }
}

# 9. RESULTADO FINAL (URL de la web)
output "url_del_proyecto" {
  value = "http://${aws_lb.main_alb.dns_name}"
}