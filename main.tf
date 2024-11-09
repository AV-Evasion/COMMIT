# providers.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

# variables.tf
variable "project_name" {
  default = "ABC"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

# vpc.tf
resource "aws_vpc" "ABC_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_subnet" "ABC_private_subnet_1" {
  vpc_id            = aws_vpc.ABC_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = "us-west-2a"

  tags = {
    Name                                            = "${var.project_name}-private-1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
    "kubernetes.io/role/internal-elb"              = "1"
  }
}

resource "aws_subnet" "ABC_private_subnet_2" {
  vpc_id            = aws_vpc.ABC_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone = "us-west-2b"

  tags = {
    Name                                            = "${var.project_name}-private-2"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
    "kubernetes.io/role/internal-elb"              = "1"
  }
}

resource "aws_eip" "ABC_nat" {
  domain = "vpc"
}

resource "aws_internet_gateway" "ABC_igw" {
  vpc_id = aws_vpc.ABC_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_nat_gateway" "ABC_nat" {
  allocation_id = aws_eip.ABC_nat.id
  subnet_id     = aws_subnet.ABC_private_subnet_1.id

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_route_table" "ABC_private" {
  vpc_id = aws_vpc.ABC_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ABC_nat.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "ABC_private_1" {
  subnet_id      = aws_subnet.ABC_private_subnet_1.id
  route_table_id = aws_route_table.ABC_private.id
}

resource "aws_route_table_association" "ABC_private_2" {
  subnet_id      = aws_subnet.ABC_private_subnet_2.id
  route_table_id = aws_route_table.ABC_private.id
}

# security.tf
resource "aws_security_group" "ABC_eks_cluster" {
  name        = "${var.project_name}-eks-cluster"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.ABC_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# eks.tf
resource "aws_iam_role" "ABC_eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ABC_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.ABC_eks_cluster.name
}

resource "aws_eks_cluster" "ABC_eks" {
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.ABC_eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids         = [aws_subnet.ABC_private_subnet_1.id, aws_subnet.ABC_private_subnet_2.id]
    security_group_ids = [aws_security_group.ABC_eks_cluster.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.ABC_eks_cluster_policy
  ]
}

# alb-controller.tf
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.ABC_eks.name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  depends_on = [aws_eks_cluster.ABC_eks]
}

# argocd.tf
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"
  create_namespace = true

  values = [
    <<-EOT
    server:
      ingress:
        enabled: true
        annotations:
          kubernetes.io/ingress.class: alb
          alb.ingress.kubernetes.io/scheme: internal
          alb.ingress.kubernetes.io/target-type: ip
          alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    EOT
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}