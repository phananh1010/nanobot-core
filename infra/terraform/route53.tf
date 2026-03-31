# ── DNS: point hostname(s) at the deployment Elastic IP ────────────────────────
# Requires an existing public hosted zone in Route 53 (e.g. mintanalytic.com).

data "aws_route53_zone" "primary" {
  count        = var.route53_zone_name != "" ? 1 : 0
  name         = "${var.route53_zone_name}."
  private_zone = false
}

resource "aws_route53_record" "nanobot" {
  for_each = var.route53_zone_name != "" ? toset(var.route53_a_records) : toset([])

  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = each.value
  type    = "A"
  ttl     = 300
  records = [aws_eip.nanobot.public_ip]
}
