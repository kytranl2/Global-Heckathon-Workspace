provider "aws" {
  region = "us-east-1"
}

#Create a VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "ecs-vpc"
  }
}

#Create a public Subnet
resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "ecs-public-subnet"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
    Name = "ecs-public-subnet-2"
  }
}

#Create an Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "ecs-igw"
  }
}

#Create a Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "ecs-public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}


resource "aws_cloudwatch_log_group" "springboot_logs" {
  name              = "/ecs/springboot-task"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "otel_collector_logs" {
  name              = "/ecs/otel-collector"
  retention_in_days = 7
}


# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  # Allow inbound HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-sg"
  }
}


#Security Group
resource "aws_security_group" "ecs_sg" {
  #name        = "ecs-sg"
  description = "Allow inbound traffic from ALB"
  vpc_id      = aws_vpc.main.id

  # ✅ Allow ALB to connect to ECS tasks on port 8080
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Reference to the ALB SG
  }

  # Allow HTTP traffic on port 80 from anywhere (optional, may not be needed for ECS)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-sg"
  }
}



resource "aws_ecs_cluster" "my_first_ecs_cluster" {
  name = "my_first_ecs_cluster"
}


#IAM role for ECS task execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect = "Allow"
        Sid = ""
      },
    ]
  })
}


resource "aws_iam_role_policy_attachment" "ecs_instance_policy_attach" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}


#Define an IAM role for ECS instances
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Effect    = "Allow"
        Sid       = ""
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

resource "aws_iam_role_policy_attachment" "ecs_ecr_readonly" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Get ECS Optimized AMI
data "aws_ami" "ecs_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }
}


# Launch Template
resource "aws_launch_template" "ecs" {
  name_prefix   = "ecs-launch-"
  image_id      = data.aws_ami.ecs_ami.id
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  user_data = base64encode(<<EOF
#!/bin/bash
echo ECS_CLUSTER=${aws_ecs_cluster.my_first_ecs_cluster.name} >> /etc/ecs/ecs.config
EOF
  )


  vpc_security_group_ids = [aws_security_group.ecs_sg.id]
}

# Auto Scaling Group for ECS EC2 Instances
resource "aws_autoscaling_group" "ecs" {
  desired_capacity     = 1
  max_size             = 1
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.public.id, aws_subnet.public_2.id]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "ecs-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ECS Task Definition for Spring Boot App
resource "aws_ecs_task_definition" "springboot" {
  family             = "springboot-task"
  network_mode       = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                = "256"
  memory             = "512"
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "springboot-app",
      image     = "198413840755.dkr.ecr.us-east-1.amazonaws.com/springboot-app:1.0.5",
      essential = true,
      portMappings = [
        {
          containerPort = 8080,
          hostPort      = 8080
        }
      ],
      environment = [
        {
          name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
          value = "http://localhost:4317"
        },
        {
          name  = "OTEL_METRICS_EXPORTER"
          value = "otlp"
        },
        {
          name  = "OTEL_TRACES_EXPORTER"
          value = "otlp"
        },
        {
          name  = "OTEL_SERVICE_NAME"
          value = "springboot-app"
        }
      ],
      mountPoints = [
        {
          containerPath = "/otel"
          sourceVolume  = "otel-volume"
          readOnly      = false
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = "/ecs/springboot-task",
          awslogs-region        = "us-east-1",
          awslogs-stream-prefix = "ecs"
        }
      }
    },
    {
      name      = "otel-collector",
      image     = "198413840755.dkr.ecr.us-east-1.amazonaws.com/otel-collector:1.0.0",
      essential = false,
      portMappings = [
        {
          containerPort = 4317
          hostPort      = 4317
        },
        {
          containerPort = 4318
          hostPort      = 4318
        }
      ],
      command = [
        "--config=/etc/otel-collector-config.yaml"
      ],
      mountPoints = [
        {
          containerPath = "/etc"
          sourceVolume  = "otel-volume"
          readOnly      = false
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = "/ecs/otel-collector",
          awslogs-region        = "us-east-1",
          awslogs-stream-prefix = "otel"
        }
      }
    }
  ])

  volume {
    name = "otel-volume"
    # Fargate doesn't support host_path; we just declare the name
  }

  depends_on = [
    aws_cloudwatch_log_group.springboot_logs,
    aws_cloudwatch_log_group.otel_collector_logs
  ]


}



# Create the ALB
resource "aws_lb" "alb" {
  name               = "springboot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_2.id]

  tags = {
    Name = "springboot-alb"
  }
}

# Create Target Group
resource "aws_lb_target_group" "springboot_tg" {
  name     = "springboot-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/api/hello/welcome"
    protocol            = "HTTP"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = {
    Name = "springboot-tg"
  }
}

# Create Listener for ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.springboot_tg.arn
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_lb_target_group.springboot_tg]
}

#ECS Service
resource "aws_ecs_service" "springboot_service" {
  name            = "springboot-service"
  cluster         = aws_ecs_cluster.my_first_ecs_cluster.id
  task_definition = aws_ecs_task_definition.springboot.arn
  desired_count   = 1
  launch_type     = "FARGATE"  # or FARGATE if using awsvpc mode

  network_configuration {
    subnets          = [aws_subnet.public.id, aws_subnet.public_2.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.springboot_tg.arn
    container_name   = "springboot-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}

