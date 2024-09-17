# Provider configuration: Connect to AWS using credentials from AWS CLI
provider "aws" {
  region = "us-east-1" # Specify AWS region
  # AWS credentials will be automatically picked from the environment variables or CLI configuration
}

# Create a VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "RoyalHotelVPC"
  }
}

# Create a subnet inside the VPC
resource "aws_subnet" "main_subnet" {
  vpc_id = aws_vpc.main_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "RoyalHotelSubnet"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "RoyalHotelInternetGateway"
  }
}

# Create a route table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "RoyalHotelPublicRouteTable"
  }
}

# Associate the route table with the subnet
resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id = aws_subnet.main_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Create a security group to allow SSH access
resource "aws_security_group" "allow_ssh" {
  vpc_id = aws_vpc.main_vpc.id

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow SSH from anywhere
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AllowSSH"
  }
}

# Import your existing key pair or create a new one
resource "aws_key_pair" "royal_hotel_key" {
  key_name   = "royal_hotel_vm_key"
  public_key = file("/home/jeffpb213gmail/.ssh/royal_hotel_vm_key.pub") # Ensure this path is correct
}

# Create an EC2 instance
resource "aws_instance" "sandbox" {
  ami                         = "ami-0a5c3558529277641" # Amazon Linux 2 AMI
  instance_type               = "t2.micro" # Free tier eligible
  key_name                    = aws_key_pair.royal_hotel_key.key_name
  subnet_id                   = aws_subnet.main_subnet.id
  vpc_security_group_ids      = [aws_security_group.allow_ssh.id]
  associate_public_ip_address = true

  tags = {
    Name = "RoyalHotelSandbox"
  }

  # Wait for instance readiness and run Ansible
  provisioner "local-exec" {
    command = <<EOT
      # Initialize variables
      INSTANCE_ID=${aws_instance.sandbox.id}
      PUBLIC_IP=${aws_instance.sandbox.public_ip}
      WAIT_TIME=10

      # Function to check instance status
      check_instance_status() {
        INSTANCE_STATUS=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_ID --query 'InstanceStatuses[0].InstanceStatus.Status' --output text)
        SYSTEM_STATUS=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_ID --query 'InstanceStatuses[0].SystemStatus.Status' --output text)

        # Use single '=' for string comparison in /bin/sh
        if [ "$INSTANCE_STATUS" = "ok" ] && [ "$SYSTEM_STATUS" = "ok" ]; then
          return 0
        else
          return 1
        fi
      }

      # Wait until instance is ready
      while true; do
        if check_instance_status; then
          echo "Instance is ready."
          break
        else
          echo "Waiting for instance to be ready..."
          sleep $WAIT_TIME
          WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
        fi
      done

      # Check SSH connectivity
      echo "Checking SSH connectivity..."
      while ! nc -z -w 30 ${aws_instance.sandbox.public_ip} 22; do
        echo "SSH port not open yet. Waiting..."
        sleep 10
      done

      # Run Ansible playbook with SSH key checking disabled
      echo "Running Ansible playbook..."
      ansible-playbook -i '${aws_instance.sandbox.public_ip},' -u ec2-user --private-key ~/.ssh/royal_hotel_vm_key playbook.yml --ssh-extra-args="-o StrictHostKeyChecking=no"
    EOT
  }
}

# Output the instance public IP
output "instance_public_ip" {
  value = aws_instance.sandbox.public_ip
}
