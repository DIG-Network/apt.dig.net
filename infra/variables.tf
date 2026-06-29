# Input variables — every environment-specific value is a var so this module is
# reusable and nothing is hard-coded. Defaults mirror the dig.net / status.dig.net
# deploy targets (AWS acct 873139760123, us-east-1).

variable "aws_region" {
  description = "AWS region. Must be us-east-1 for the CloudFront/ACM pairing."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Public hostname the repo is served at."
  type        = string
  default     = "apt.dig.net"
}

variable "s3_bucket" {
  description = "S3 bucket holding the static apt repo (Packages/Release/InRelease/pool/...)."
  type        = string
  default     = "apt-dig-net"
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route53 hosted zone id for dig.net (the apt.dig.net A/AAAA aliases are created in
    it). The dig.net zone is Z09143862Q3QQA5P9F8QY per the ecosystem deploy notes;
    override if it differs.
  EOT
  type        = string
  default     = "Z09143862Q3QQA5P9F8QY"
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of the *.dig.net wildcard ACM certificate (us-east-1) reused by every DIG
    static site. The ecosystem cert is
    aafcd24b-513c-4959-a7d6-c303f071e2de; supply the full ARN.
  EOT
  type        = string
  default     = "arn:aws:acm:us-east-1:873139760123:certificate/aafcd24b-513c-4959-a7d6-c303f071e2de"
}

variable "price_class" {
  description = "CloudFront price class (PriceClass_100 = NA+EU, cheapest)."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default = {
    Project   = "apt.dig.net"
    ManagedBy = "terraform"
    System    = "DIG Network"
  }
}
