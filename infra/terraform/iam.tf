# IAM role that the EC2 instance assumes, granting it permission to read
# secrets from SSM Parameter Store without any long-lived credentials on disk.

resource "aws_iam_role" "nanobot_instance" {
  name = "${local.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "${local.name_prefix}-ssm-read"
  role = aws_iam_role.nanobot_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMGetParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project}/*"
      },
      {
        Sid      = "KMSDecryptSSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Allows SSM Session Manager access (optional: lets you open a shell without SSH).
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.nanobot_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nanobot" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.nanobot_instance.name
}
