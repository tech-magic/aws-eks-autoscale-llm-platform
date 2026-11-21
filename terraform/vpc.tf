################################################################################
# 1. DYNAMIC IP LOOKUP & DATA CENTER DISCOVERY (Pre-Flight Checks)
# ------------------------------------------------------------------------------
# Why do we need this?
# Before building our private cloud network, Terraform runs two quick lookups:
#   1. Checks your laptop's current public IP address so we can lock down the
#      Kubernetes admin API strictly to your home/office computer.
#   2. Asks AWS which physical data centers ("Availability Zones") are healthy
#      and ready in your chosen region so we can spread servers across two
#      separate buildings for high availability.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Detect Your Current Public IP Address
# ------------------------------------------------------------------------------
# Sends a quick web request to AWS's official IP-checker service (just like
# visiting "whatismyip.com") to find the exact internet address you are using.
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  # Clean up any invisible newline characters at the end of the response (`chomp`)
  # and append "/32", which in networking notation means "this single exact IP
  # address and nobody else" (e.g., "203.0.113.45/32").
  home_ip_cidr = "${chomp(data.http.my_public_ip.response_body)}/32"
}

# ------------------------------------------------------------------------------
# Step 1B: Find Available Physical Data Centers (Availability Zones)
# ------------------------------------------------------------------------------
# Queries AWS for a list of active data centers in our region (such as
# `us-east-1a`, `us-east-1b`, etc.) so we don't hardcode zone names.
data "aws_availability_zones" "available" {
  state = "available"
}


################################################################################
# 2. VIRTUAL PRIVATE CLOUD & SUBNETS (Your Isolated Cloud Neighborhood)
# ------------------------------------------------------------------------------
# Why do we need this?
# A VPC (Virtual Private Cloud) is your own private, walled-off section of the
# AWS cloud—completely isolated from other AWS customers.
#
# Inside this VPC, we carve out two "Subnets" (smaller network neighborhoods),
# placed in two separate physical data centers (Availability Zones). AWS EKS
# requires at least two Availability Zones so your cluster stays resilient if
# one data center ever experiences an outage.
################################################################################

# ------------------------------------------------------------------------------
# Step 2A: Create the Main Private Cloud Network (VPC)
# ------------------------------------------------------------------------------
resource "aws_vpc" "this" {
  # The master pool of private IP addresses (e.g., "10.0.0.0/16" = 65,536 IPs)
  cidr_block = var.vpc_cidr

  # Enable internal DNS names so servers and EFS storage drives can find each
  # other using friendly hostnames instead of raw IP numbers
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "vpc-${local.eks_cluster_name}"
    project = local.eks_cluster_name
  }
}

# ------------------------------------------------------------------------------
# Step 2B: Create Two Public Subnets Across Different Data Centers
# ------------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count  = 2               # Create 2 subnets (index 0 and index 1)
  vpc_id = aws_vpc.this.id # Place both subnets inside our new VPC

  # Automatically slice the master VPC IP range ("10.0.0.0/16") into two smaller
  # /20 blocks ("10.0.0.0/20" and "10.0.16.0/20" — 4,096 IP addresses each).
  cidr_block = cidrsubnet(var.vpc_cidr, 4, count.index)

  # Place subnet 0 in the 1st data center and subnet 1 in the 2nd data center
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Automatically assign a public IPv4 address to any server launched here so it
  # can reach the internet (to download Docker images & Hugging Face models)
  # without needing an expensive AWS NAT Gateway (~$32/month saved).
  map_public_ip_on_launch = true

  # CRITICAL DISCOVERY TAGS:
  # Kubernetes, AWS Load Balancers, and Karpenter inspect subnet tags to decide
  # where they are allowed to place resources:
  tags = {
    Name = "subnet-${local.eks_cluster_name}-public-${count.index}"

    # Tells Kubernetes where it can create public-facing Load Balancers
    "kubernetes.io/role/elb" = "1"

    # Tells Kubernetes where it can create internal Load Balancers (like our vLLM Router NLB)
    "kubernetes.io/role/internal-elb" = "1"

    # Tells Karpenter it is allowed to launch dynamic GPU servers in these subnets
    "karpenter.sh/discovery" = local.eks_cluster_name

    project = local.eks_cluster_name
  }
}


################################################################################
# 3. INTERNET GATEWAY & ROUTING RULES (Connecting the VPC to the Outside World)
# ------------------------------------------------------------------------------
# Why do we need this?
# By default, a new VPC has no doors to the outside internet. To let our GPU
# servers download AI container images from GitHub/AWS ECR and fetch model
# weights from Hugging Face, we attach an "Internet Gateway" (a virtual fiber
# modem) and configure a "Route Table" (network GPS directions) pointing to it.
################################################################################

# ------------------------------------------------------------------------------
# Step 3A: Attach the Virtual Internet Modem (Internet Gateway)
# ------------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "igw-${local.eks_cluster_name}"
    project = local.eks_cluster_name
  }
}

# ------------------------------------------------------------------------------
# Step 3B: Create Network GPS Directions (Public Route Table)
# ------------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  # Default Internet Route: Any network traffic heading outside our local
  # 10.0.0.0/16 neighborhood ("0.0.0.0/0" = anywhere on the public internet)
  # should be sent through our Internet Gateway.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name    = "rt-${local.eks_cluster_name}-public"
    project = local.eks_cluster_name
  }
}

# ------------------------------------------------------------------------------
# Step 3C: Activate the Routing Rules on Both Subnets
# ------------------------------------------------------------------------------
# Connects our two subnets (from Step 2B) to the Public Route Table (Step 3B)
# so servers in both data centers can actually use the Internet Gateway.
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}