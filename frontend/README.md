## S3

#### aws_s3_bucket

Defines the primary storage location.

#### aws_s3_bucket_website_configuration

Set up the S3 bucket to behave like a web server.

#### aws_s3_bucket_ownership_controls

Establishes the default owner of the object uploaded to the bucket.

#### aws_s3_bucket_public_access_block

Ensures the bucket is NOT publicly accessible.

#### aws_s3_bucket_acl

Depends on `aws_s3_bucket_ownership_controls` and `aws_s3_bucket_public_access_block`.
Enforces the access level for the bucket to "private".

#### aws_s3_object

Ensures to deploy all static files from our `dist_dir`.


## ACM

#### aws_acm_certificate

Provision an SSL certificate for out domain.

#### aws_acm_certificate_validation

Ensures certificate validation.

#### aws_route53_record

SSL certificate necessitates DNS records for its validation.

## CloudFront

#### aws_cloudfront_origin_access_control

Creates and AWS CloudFront OAC.
OAC use AWS Identity and Access Management (IAM) role trusts to provide CloudFront with short-term credentials to access your S3 bucket

#### aws_cloudfront_distribution

Primary config of the CDN:
- `origin` -> origin of the content
- `default_cache_behavior` -> caching policies, HTTP methods, and content delivery through HTTPS
- `aliases` -> configures domain names associated with CloudFront
- `restrictions` -> geo-restrictions
- `viewer_certificate` -> associates SSL certificate with the distribution, enabling HTTPS access

#### aws_cloudfront_function

This function redirects "www." to root domain.

Benefits over Lambda:
1. Simplicity
2. Low Latency
3. Cost-Effective
4. Ease of Deployment

## S3-Policy

#### aws_s3_bucket_policy

Grants CloudFront read-only access via Origin Access Control (OAC)

## Route53

#### aws_route53_zone

We will reuse a hosted zone with the specified domain.
Here we can define how to route traffic.

#### aws_route53_record "root_a"

Record of type "A" is essential for translating domain names into IP addresses.
This points "root" domain to CloudFront distribution.

#### aws_route53_record "www_a"

This points "www." domain to CloudFront distribution.


### How to setup

1. create an s3 bucket with a random name using the script in bin directory
2. take the name of the bucket and add it to `.tfvars`