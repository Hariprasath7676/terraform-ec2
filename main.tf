#####################################
# Ubuntu 24.04 Latest AMI
#####################################

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

#####################################
# Security Group
#####################################

resource "aws_security_group" "server" {

  name        = var.security_group_name
  description = "Security Group for ${var.instance_name}"

  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.security_group_name
  }
}
#####################################
# SSH Key Generation
#####################################

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

#####################################
# AWS Key Pair
#####################################

resource "aws_key_pair" "generated" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh.public_key_openssh
}

#####################################
# Upload PEM to S3
#####################################

resource "aws_s3_object" "private_key" {

  bucket = var.s3_bucket

  key = "${var.s3_key_path}/${var.key_name}.pem"

  content = tls_private_key.ssh.private_key_pem

  server_side_encryption = "AES256"
}

#####################################
# EC2 Instance
#####################################

resource "aws_instance" "server" {

  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  subnet_id = var.subnet_id

  key_name = aws_key_pair.generated.key_name

  vpc_security_group_ids = [
    aws_security_group.server.id
  ]

  iam_instance_profile = var.iam_instance_profile

  associate_public_ip_address = false

  root_block_device {

    volume_size = var.root_volume_size

    volume_type = "gp3"

    encrypted = true
  }

  tags = {
    Name = var.instance_name
  }
}

#####################################
# Additional EBS Volume
#####################################

resource "aws_ebs_volume" "data" {

  availability_zone = aws_instance.server.availability_zone

  size = var.data_volume_size

  type = "gp3"

  encrypted = true

  tags = {
    Name = "${var.instance_name}-data"
  }
}

#####################################
# Attach Volume
#####################################

resource "aws_volume_attachment" "data" {

  device_name = "/dev/sdf"

  volume_id = aws_ebs_volume.data.id

  instance_id = aws_instance.server.id
}
