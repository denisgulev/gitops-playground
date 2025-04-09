resource "aws_iam_role" "ec2_cloudwatch_role" {
  name = "CloudWatchRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-instance-profile"
  role = aws_iam_role.ec2_cloudwatch_role.name
}

resource "aws_iam_role_policy" "cloudwatch_write" {
  name = "cloudwatch_write"
  role = aws_iam_role.ec2_cloudwatch_role.id

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "prefix_list_access_role" {
  name = "PrefixListAccessRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "prefix_list_access_profile" {
  name = "prefix-list-access-profile"
  role = aws_iam_role.prefix_list_access_role.name
}

resource "aws_iam_role_policy" "prefix_list_access_policy" {
  name = "prefix_list_access_policy"
  role = aws_iam_role.prefix_list_access_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:DescribeManagedPrefixLists",
          "ec2:GetManagedPrefixListEntries"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}
