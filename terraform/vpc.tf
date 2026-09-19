data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "${var.project_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Egress only — inbound access is via SSM, not SSH (KR ISP blocks outbound 22).
resource "aws_security_group" "node" {
  name        = "${var.project_name}-node-sg"
  description = "Egress only; access the node via SSM Session Manager"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # QEMU/libvirt live-migration data channel (block migration transfers the qcow2
  # disk over this range). `self = true` allows any two instances in this SG to
  # reach each other on these ports, so node-a and node-b are covered by one rule.
  # NOTE: libvirtd's own control channel (16509 tcp, 16514 tls) may also need to be
  # opened here once L2/L3 actually attempt a migration and hit a connection issue —
  # not added preemptively since it's unconfirmed whether OSH's libvirt pod needs it
  # exposed beyond the pod network.
  ingress {
    from_port = 49152
    to_port   = 49215
    protocol  = "tcp"
    self      = true
  }

  # L2: node-b joining the K8s cluster needs the kube-apiserver port (6443),
  # and OSH scheduling nova-compute/libvirt/OVS agents onto node-b needs
  # Calico VXLAN/BGP, OVS tunnel, and libvirtd control-channel traffic between
  # the two nodes. Rather than enumerate every port, open all traffic between
  # members of this SG — node-a and node-b are the only members, they're a
  # trusted experiment pair, and egress is already unrestricted.
  ingress {
    description = "all traffic between node-a/node-b (Calico, OVS tunnel, libvirt control+migration)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  tags = { Name = "${var.project_name}-node-sg" }
}
