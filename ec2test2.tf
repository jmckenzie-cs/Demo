# ec2-misconfigured.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Security Group with overly permissive rules (CRITICAL MISCONFIGURATION)
resource "aws_security_group" "vulnerable_sg" {
  name        = "vulnerable-test-sg"
  description = "Intentionally misconfigured security group for testing"

  # SSH open to the world (0.0.0.0/0) - CRITICAL
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RDP open to the world - CRITICAL
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All ports open to the world - CRITICAL
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic allowed (less critical but still flagged)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vulnerable-sg"
  }
}

# EC2 Instance with misconfigurations
resource "aws_instance" "vulnerable_instance" {
  ami           = "ami-0c02fb55956c7d316" # Amazon Linux 2 AMI
  instance_type = "t3.micro"
  
  # Using the vulnerable security group
  vpc_security_group_ids = [aws_security_group.vulnerable_sg.id]
  
  # No encryption on EBS volumes (CRITICAL)
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = false  # Should be true
    delete_on_termination = true
  }
  
  # Additional unencrypted EBS volume
  ebs_block_device {
    device_name = "/dev/sdf"
    volume_type = "gp3"
    volume_size = 10
    encrypted   = false  # Should be true
  }
  
  # IMDSv1 enabled (should use IMDSv2 only) - CRITICAL
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"  # Should be "required"
    http_put_response_hop_limit = 2
  }
  
  # No monitoring enabled
  monitoring = false  # Should be true for production
  
  # Public IP assignment (depending on use case, could be misconfiguration)
  associate_public_ip_address = true

  tags = {
    Name = "vulnerable-test-instance"
    Environment = "test"
  }
}

# S3 bucket with public access (bonus misconfiguration)
resource "aws_s3_bucket" "vulnerable_bucket" {
  bucket = "vulnerable-test-bucket-${random_id.bucket_suffix.hex}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# Public read access - CRITICAL
resource "aws_s3_bucket_public_access_block" "vulnerable_bucket_pab" {
  bucket = aws_s3_bucket.vulnerable_bucket.id

  block_public_acls       = false  # Should be true
  block_public_policy     = false  # Should be true
  ignore_public_acls      = false  # Should be true
  restrict_public_buckets = false  # Should be true
}

# Public bucket policy - CRITICAL
resource "aws_s3_bucket_policy" "vulnerable_bucket_policy" {
  bucket = aws_s3_bucket.vulnerable_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.vulnerable_bucket.arn}/*"
      }
    ]
  })
}

output "instance_id" {
  value = aws_instance.vulnerable_instance.id
}

output "public_ip" {
  value = aws_instance.vulnerable_instance.public_ip
}

output "security_group_id" {
  value = aws_security_group.vulnerable_sg.id
}
