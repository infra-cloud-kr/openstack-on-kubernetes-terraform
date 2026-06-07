data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = file("${path.module}/user_data.sh")

  tags = {
    Name = "${var.project_name}-node"
  }
}

# Extra raw EBS — Cinder LVM VG. user_data turns this into pv/vg cinder-volumes.
# Sized distinctly from the Rook disk so user_data picks the right device by size.
resource "aws_ebs_volume" "cinder" {
  availability_zone = aws_instance.node.availability_zone
  size              = var.cinder_volume_gb
  type              = "gp3"
  tags              = { Name = "${var.project_name}-cinder" }
}

resource "aws_volume_attachment" "cinder" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.cinder.id
  instance_id = aws_instance.node.id
}

# Extra raw EBS — Rook-Ceph OSD. No filesystem, no LVM; Rook claims the whole
# device. Sized distinctly from the Cinder disk for unambiguous identification.
resource "aws_ebs_volume" "rook" {
  availability_zone = aws_instance.node.availability_zone
  size              = var.rook_volume_gb
  type              = "gp3"
  tags              = { Name = "${var.project_name}-rook" }
}

resource "aws_volume_attachment" "rook" {
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.rook.id
  instance_id = aws_instance.node.id
}
