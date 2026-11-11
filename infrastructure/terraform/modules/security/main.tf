# Free resources: security groups. No SSH ingress (administration via SSM Session Manager).
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "StockWatch DR application host: HTTP in, HTTPS/PostgreSQL out"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  for_each          = toset(var.http_ingress_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "HTTP (frontend, /api proxy, Route 53 health checks)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS (GHCR images, SSM, AWS APIs, RDS CA truststore)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_postgres" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the DR database only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "StockWatch DR database: PostgreSQL from the app security group only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "db_postgres" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the StockWatch DR app host"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
