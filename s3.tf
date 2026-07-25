resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "front" {

  bucket = coalesce(var.s3_bucket_name, "${var.project_name}-front-${random_id.bucket_suffix.hex}")

  tags = {
    Name = "${var.project_name}/front"
  }
}

resource "aws_s3_bucket_versioning" "front" {
  bucket = aws_s3_bucket.front.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "front" {
  bucket = aws_s3_bucket.front.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "front" {
  bucket = aws_s3_bucket.front.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
