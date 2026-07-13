# ─────────────────────────────────────────────────────────────────────────────
# RDS Module
# Same database engine/config as Phase 2 EC2 deployment — only the network
# path changes (EKS nodes instead of a single EC2 instance reach it).
# No data migration required; this provisions a fresh RDS instance for the
# EKS environment. If you want to reuse Phase 2's actual data, snapshot and
# restore rather than re-running this module against the old instance.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_db_instance" "postgres" {
  identifier = "${var.project}-postgres-${var.environment}"

  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100
  storage_type           = "gp3"
  storage_encrypted      = true

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = var.vpc_security_group_ids

  publicly_accessible = false

  # Multi-AZ off by default for a learning project run for <48h.
  # Flip to true in terraform.tfvars if you want HA failover testing.
  multi_az = var.multi_az

  backup_retention_period = 0
  backup_window            = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"

  deletion_protection = false # learning project — allow clean teardown after 2 days

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  skip_final_snapshot       = true # no need to retain snapshot for a short-lived learning cluster
  final_snapshot_identifier = null

  tags = { Name = "${var.project}-postgres-${var.environment}" }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-rds-monitoring-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
