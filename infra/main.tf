# apt.dig.net infrastructure — S3 (static apt repo) behind CloudFront, fronted by
# Route53 + the reused *.dig.net ACM cert. Mirrors the dig.net / status.dig.net
# pattern: a private S3 bucket served via an Origin Access Control, CloudFront with
# the wildcard cert, and an apex-style alias record.
#
# Apt-specific wrinkle: the repo METADATA (Release/InRelease/Release.gpg/Packages*)
# must never be served stale or `apt update` will read an index that no longer matches
# the pool. So CloudFront caches the bulk of the site normally but disables caching for
# the dists/ metadata via an ordered cache behavior. (The pool/*.deb files are
# immutable-by-content and ride the default long cache.)

locals {
  s3_origin_id = "s3-${var.s3_bucket}"
}

# --- S3 bucket (private; CloudFront-only access via OAC) ----------------------------

resource "aws_s3_bucket" "apt" {
  bucket = var.s3_bucket
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "apt" {
  bucket                  = aws_s3_bucket.apt.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "apt" {
  bucket = aws_s3_bucket.apt.id
  versioning_configuration {
    status = "Enabled"
  }
}

# --- CloudFront Origin Access Control (sign requests to the private bucket) ---------

resource "aws_cloudfront_origin_access_control" "apt" {
  name                              = "${var.s3_bucket}-oac"
  description                       = "OAC for ${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed cache policies (referenced by id; stable AWS-wide).
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# --- CloudFront distribution --------------------------------------------------------

resource "aws_cloudfront_distribution" "apt" {
  enabled             = true
  comment             = "${var.domain_name} — DIG APT repository"
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = [var.domain_name]
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.apt.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.apt.id
  }

  # Default: cache the site (incl. pool/*.deb — content-addressed, safe to cache long).
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  # The apt metadata under dists/ must always be fresh, or `apt update` reads a Release
  # that no longer matches the pool. Disable caching for it.
  ordered_cache_behavior {
    path_pattern           = "dists/*"
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
    compress               = true
  }

  # The published public key (dig.gpg) is stable but small — keep it uncached so a key
  # rotation propagates immediately.
  ordered_cache_behavior {
    path_pattern           = "dig.gpg"
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- S3 bucket policy: allow only this CloudFront distribution (via OAC) ------------

data "aws_iam_policy_document" "apt" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.apt.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.apt.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "apt" {
  bucket = aws_s3_bucket.apt.id
  policy = data.aws_iam_policy_document.apt.json
}

# --- Route53 alias records (apt.dig.net -> CloudFront) ------------------------------

resource "aws_route53_record" "apt_a" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.apt.domain_name
    zone_id                = aws_cloudfront_distribution.apt.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apt_aaaa" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.apt.domain_name
    zone_id                = aws_cloudfront_distribution.apt.hosted_zone_id
    evaluate_target_health = false
  }
}
