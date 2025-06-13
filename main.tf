###############################################################################
# PROVIDER
###############################################################################
provider "aws" {
  region = "us-east-1"
}

###############################################################################
# NETWORKING
###############################################################################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "ecs-vpc-2" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "ecs-public-subnet-2-a" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = { Name = "ecs-public-subnet-2-b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "ecs-igw2" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "ecs-public-route-table" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# LOG GROUPS
###############################################################################
resource "aws_cloudwatch_log_group" "springboot_logs" {
  name              = "/ecs/springboot-task"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "otel_collector_logs" {
  name              = "/ecs/otel-collector"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "otel_importer_logs" {
  name              = "/ecs/otel-importer"
  retention_in_days = 7
}

###############################################################################
# KINESIS STREAM
###############################################################################
resource "aws_kinesis_stream" "telemetry_stream" {
  name             = "telemetry-stream"
  shard_count      = 1
  retention_period = 24
}

###############################################################################
# SECURITY GROUPS
###############################################################################
# ALB for Spring Boot (80 → ecs_sg:8080)
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP(80) from Internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

# ECS tasks for Spring Boot allow only ALB→8080
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Allow 8080 from Spring Boot ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecs-sg" }
}

# ALB for OTLP Exporter (4317 → exporter_sg:4317)
resource "aws_security_group" "exporter_alb_sg" {
  name        = "exporter-alb-sg"
  description = "Allow OTLP(4317) from app tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 4317
    to_port         = 4317
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "exporter-alb-sg" }
}

# ECS tasks for Exporter allow only exporter ALB→4317
resource "aws_security_group" "exporter_sg" {
  name        = "exporter-sg"
  description = "Allow 4317 from exporter ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 4317
    to_port         = 4317
    protocol        = "tcp"
    security_groups = [aws_security_group.exporter_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "exporter-sg" }
}

###############################################################################
# ECS CLUSTER
###############################################################################
resource "aws_ecs_cluster" "spring_boot_ecs" {
  name = "spring_boot_ecs"
}

###############################################################################
# IAM ROLES & POLICIES
###############################################################################
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "exporter_task_role" {
  name               = "otel-exporter-task-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy" "exporter_kinesis" {
  name   = "ExporterKinesisAccess"
  role   = aws_iam_role.exporter_task_role.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["kinesis:PutRecord","kinesis:PutRecords"],
      Resource = aws_kinesis_stream.telemetry_stream.arn
    }]
  })
}

###############################################################################
# INTERNAL ALB FOR OTLP EXPORTER
###############################################################################
resource "aws_lb" "exporter_alb" {
  name               = "otel-exporter-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.exporter_alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_2.id]
  tags               = { Name = "otel-exporter-alb" }
}

resource "aws_lb_target_group" "exporter_tg" {
  name        = "otel-exporter-tg"
  port        = 4317
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/"
    matcher             = "200-499"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "otel-exporter-tg" }
}

resource "aws_lb_listener" "exporter_listener" {
  load_balancer_arn = aws_lb.exporter_alb.arn
  port              = 4317
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.exporter_tg.arn
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# SPRINGBOOT ECS TASK DEFINITION
###############################################################################
resource "aws_ecs_task_definition" "springboot" {
  family                   = "springboot-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.exporter_task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = <<EOF
[
  {
    "name": "springboot-app",
    "image": "198413840755.dkr.ecr.us-east-1.amazonaws.com/springboot-app:1.0.5",
    "essential": true,
    "portMappings": [
      { "containerPort": 8080, "hostPort": 8080, "protocol": "tcp" }
    ],
    "environment": [
      { "name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://${aws_lb.exporter_alb.dns_name}:4317" },
      { "name": "OTEL_EXPORTER_OTLP_PROTOCOL", "value": "grpc" },
      { "name": "OTEL_METRICS_EXPORTER",         "value": "otlp" },
      { "name": "OTEL_TRACES_EXPORTER",          "value": "otlp" },
      { "name": "OTEL_SERVICE_NAME",             "value": "springboot-app" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group":         "/ecs/springboot-task",
        "awslogs-region":        "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    }
  },
  {
    "name": "otel-collector",
    "image": "198413840755.dkr.ecr.us-east-1.amazonaws.com/otel-collector:1.0.0",
    "essential": false,
    "portMappings": [
      { "containerPort": 4317, "hostPort": 4317, "protocol": "tcp" },
      { "containerPort": 4318, "hostPort": 4318, "protocol": "tcp" }
    ],
    "command": ["--config=/etc/otel-collector-config.yaml"],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group":         "/ecs/otel-collector",
        "awslogs-region":        "us-east-1",
        "awslogs-stream-prefix": "otel"
      }
    }
  }
]
EOF

  depends_on = [
    aws_cloudwatch_log_group.springboot_logs,
    aws_cloudwatch_log_group.otel_collector_logs,
    aws_cloudwatch_log_group.otel_importer_logs,
  ]
}

###############################################################################
# OTEL EXPORTER ECS TASK DEFINITION
###############################################################################
resource "aws_ecs_task_definition" "otel_exporter" {
  family                   = "otel-exporter"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.exporter_task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = <<EOF
[
  {
    "name": "otel-exporter",
    "image": "198413840755.dkr.ecr.us-east-1.amazonaws.com/otel-exporter:1.0.0",
    "essential": true,
    "portMappings": [
      { "containerPort": 4317, "hostPort": 4317, "protocol": "tcp" }
    ],
    "environment": [
      { "name": "AWS_REGION", "value": "us-east-1" },
      { "name": "STREAM_NAME", "value": "${aws_kinesis_stream.telemetry_stream.name}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group":         "/ecs/otel-importer",
        "awslogs-region":        "us-east-1",
        "awslogs-stream-prefix": "importer"
      }
    }
  }
]
EOF

  depends_on = [
    aws_cloudwatch_log_group.otel_importer_logs,
  ]
}

###############################################################################
# ALB & ECS SERVICE FOR SPRINGBOOT
###############################################################################
resource "aws_lb" "alb" {
  name               = "springboot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_2.id]
  tags               = { Name = "springboot-alb" }
}

resource "aws_lb_target_group" "springboot_tg" {
  name        = "springboot-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
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

  tags = { Name = "springboot-tg" }
}

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
}

resource "aws_ecs_service" "springboot_service" {
  name            = "springboot-service"
  cluster         = aws_ecs_cluster.spring_boot_ecs.id
  task_definition = aws_ecs_task_definition.springboot.arn
  desired_count   = 1
  launch_type     = "FARGATE"

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

###############################################################################
# ECS SERVICE FOR OTEL EXPORTER
###############################################################################
resource "aws_ecs_service" "otel_exporter_svc" {
  name            = "otel-exporter-service"
  cluster         = aws_ecs_cluster.spring_boot_ecs.id
  task_definition = aws_ecs_task_definition.otel_exporter.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id, aws_subnet.public_2.id]
    security_groups  = [aws_security_group.exporter_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.exporter_tg.arn
    container_name   = "otel-exporter"
    container_port   = 4317
  }

  depends_on = [aws_lb_listener.exporter_listener]
}
