# Outputs — the values the deploy workflow + the parent provisioner need:
# the bucket name, the CloudFront distribution id (for invalidations), and the URL.

output "s3_bucket" {
  description = "S3 bucket holding the apt repo (set repo var APT_S3_BUCKET to this)."
  value       = aws_s3_bucket.apt.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution id (set repo var APT_CLOUDFRONT_DISTRIBUTION_ID to this)."
  value       = aws_cloudfront_distribution.apt.id
}

output "cloudfront_domain_name" {
  description = "The CloudFront *.cloudfront.net domain (target of the Route53 alias)."
  value       = aws_cloudfront_distribution.apt.domain_name
}

output "repo_url" {
  description = "The public repository URL users add to their apt sources."
  value       = "https://${var.domain_name}"
}
