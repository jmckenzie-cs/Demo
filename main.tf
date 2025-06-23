provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region to deploy resources"
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t2.micro"
}

variable "key_name" {
  description = "Name of the SSH key pair"
  type        = string
  # No default - you must specify your key pair name
}

variable "allowed_cidr" {
  description = "CIDR block allowed to access Docker ports (restrict this for security)"
  default     = "0.0.0.0/0"  # WARNING: This allows access from anywhere
}

# VPC and networking resources
resource "aws_vpc" "docker_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "docker-vpc"
  }
}

resource "aws_internet_gateway" "docker_igw" {
  vpc_id = aws_vpc.docker_vpc.id
  
  tags = {
    Name = "docker-igw"
  }
}

resource "aws_subnet" "docker_subnet" {
  vpc_id                  = aws_vpc.docker_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  
  tags = {
    Name = "docker-subnet"
  }
}

resource "aws_route_table" "docker_rt" {
  vpc_id = aws_vpc.docker_vpc.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.docker_igw.id
  }
  
  tags = {
    Name = "docker-route-table"
  }
}

resource "aws_route_table_association" "docker_rta" {
  subnet_id      = aws_subnet.docker_subnet.id
  route_table_id = aws_route_table.docker_rt.id
}

# Security group for Docker
resource "aws_security_group" "docker_sg" {
  name        = "docker-sg"
  description = "Allow Docker and SSH traffic"
  vpc_id      = aws_vpc.docker_vpc.id

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "SSH access"
  }

  # Docker daemon TCP socket (unencrypted)
  ingress {
    from_port   = 2375
    to_port     = 2375
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "Docker daemon unencrypted"
  }

  # Docker daemon TLS socket (encrypted)
  ingress {
    from_port   = 2376
    to_port     = 2376
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "Docker daemon TLS"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "docker-security-group"
  }
}

# EC2 instance
resource "aws_instance" "docker_instance" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.docker_sg.id]
  subnet_id              = aws_subnet.docker_subnet.id

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              systemctl start docker
              systemctl enable docker
              
              # Configure Docker to listen on TCP ports
              mkdir -p /etc/systemd/system/docker.service.d
              cat > /etc/systemd/system/docker.service.d/override.conf << 'EOL'
              [Service]
              ExecStart=
              ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375
              EOL
              
              systemctl daemon-reload
              systemctl restart docker
              EOF

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "docker-instance"
  }
}

# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Output values
output "instance_id" {
  value = aws_instance.docker_instance.id
}

output "public_ip" {
  value = aws_instance.docker_instance.public_ip
}

output "docker_connection_string" {
  value = "docker -H tcp://${aws_instance.docker_instance.public_ip}:2375 info"
}
