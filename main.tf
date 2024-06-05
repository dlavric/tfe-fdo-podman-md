# DNS
data "aws_route53_zone" "zone" {
  name = var.tfe_domain
}


resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.zone.zone_id
  #name    = "fdo-docker.${data.aws_route53_zone.zone.name}"
  name = "${var.tfe_subdomain}.${data.aws_route53_zone.zone.name}"
  type = "A"
  ttl  = "300"
  #records = ["34.253.52.28"]
  records = [aws_eip.eip.public_ip]
}

# Create Certificates
resource "tls_private_key" "private_key" {
  algorithm = "RSA"
}

resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.private_key.private_key_pem
  email_address   = var.email
}

resource "acme_certificate" "certificate" {
  account_key_pem = acme_registration.reg.account_key_pem
  #common_name                  = "fdo-docker.${data.aws_route53_zone.zone.name}"
  #subject_alternative_names    = ["fdo-docker.${data.aws_route53_zone.zone.name}"]
  common_name                  = "${var.tfe_subdomain}.${data.aws_route53_zone.zone.name}"
  subject_alternative_names    = ["${var.tfe_subdomain}.${data.aws_route53_zone.zone.name}"]
  disable_complete_propagation = true

  dns_challenge {
    provider = "route53"
    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.zone.zone_id,
      AWS_REGION         = var.aws_region
    }
  }
}

# Add my certificates to a S3 Bucket
resource "aws_s3_bucket" "s3bucket" {
  bucket = var.bucket

  tags = {
    Name        = "${var.prefix} FDO Bucket"
    Environment = "Dev"
  }
}

resource "aws_s3_object" "object" {
  for_each = toset(["certificate_pem", "issuer_pem", "private_key_pem"])
  bucket   = aws_s3_bucket.s3bucket.bucket
  key      = "ssl-certs/${each.key}"
  content  = lookup(acme_certificate.certificate, "${each.key}")
}

resource "aws_s3_object" "object_full_chain" {
  bucket  = aws_s3_bucket.s3bucket.bucket
  key     = "ssl-certs/full_chain"
  content = "${acme_certificate.certificate.certificate_pem}${acme_certificate.certificate.issuer_pem}"
}

# Create network
resource "aws_vpc" "vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "${var.prefix}-vpc"
  }
}

resource "aws_subnet" "publicsub" {
  vpc_id     = aws_vpc.vpc.id
  cidr_block = "10.0.1.0/24"

  tags = {
    Name = "${var.prefix}-public-subnet"
  }
}


resource "aws_internet_gateway" "internetgw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.prefix}-internet-gateway"
  }
}

resource "aws_route_table" "route" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internetgw.id
  }

  tags = {
    Name = "${var.prefix}-route"
  }
}

resource "aws_route_table_association" "route_association" {
  subnet_id      = aws_subnet.publicsub.id
  route_table_id = aws_route_table.route.id
}

resource "aws_security_group" "securitygp" {

  vpc_id = aws_vpc.vpc.id

  ingress {
    description = "https-access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ssh-access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "egress-rule"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    type = "${var.prefix}-security-group"
  }
}


resource "aws_network_interface" "nic" {
  subnet_id       = aws_subnet.publicsub.id
  security_groups = [aws_security_group.securitygp.id]
}

resource "aws_eip" "eip" {
  instance = aws_instance.instance.id
  domain   = "vpc"
}

# Create roles and policies to attach to the instance
resource "aws_iam_role" "role" {
  name = "${var.prefix}-role-docker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "profile" {
  name = "${var.prefix}-profile-docker"
  role = aws_iam_role.role.name
}

resource "aws_iam_role_policy" "policy" {
  name = "${var.prefix}-policy-docker"
  role = aws_iam_role.role.id

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "s3:ListBucket",
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        "Resource" : [
          "arn:aws:s3:::*/*"
        ]
      }
    ]
  })
}

resource "aws_key_pair" "key-pair" {
  key_name   = var.key_pair
  public_key = file("~/.ssh/id_rsa.pub")
}

# Create EC2 instance
resource "aws_instance" "instance" {
  # to prevent VM created before certs are created
  depends_on = [aws_s3_object.object, aws_s3_object.object_full_chain]

  ami                  = "ami-0bd23a7080ec75f4d" # eu-west-3 redhat machine
  instance_type        = "m5.xlarge"
  iam_instance_profile = aws_iam_instance_profile.profile.name

  credit_specification {
    cpu_credits = "unlimited"
  }

  key_name = aws_key_pair.key-pair.key_name

  root_block_device {
    volume_size = 50
  }

  user_data = templatefile("fdo_ent.yaml", {
    tfe_version   = var.tfe_version,
    tfe_hostname  = var.tfe_hostname,
    enc_password  = var.enc_password,
    email         = var.email,
    username      = var.username,
    password      = var.password,
    bucket        = var.bucket,
    license_value = var.license_value
  })

  network_interface {
    network_interface_id = aws_network_interface.nic.id
    device_index         = 0
  }

  tags = {
    Name = "${var.prefix}-tfe-fdodocker"
  }

}
