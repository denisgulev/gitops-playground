locals {
  dist_dir    = "${path.module}/dist"
  module_name = basename(abspath(path.module))
  prefix      = var.prefix
  ec2_dns     = try(data.aws_ssm_parameter.ec2_dns.value, var.ec2_dns)

  # Aligns file extensions with their appropriate MIME types, guaranteeing accurate content delivery for various assets.
  content_types = {
    ".html" : "text/html",
    ".css" : "text/css",
    ".js" : "application/javascript",
    ".json" : "application/json",
    ".xml" : "application/xml",
    ".jpg" : "image/jpeg",
    ".jpeg" : "image/jpeg",
    ".png" : "image/png",
    ".gif" : "image/gif",
    ".svg" : "image/svg+xml",
    ".webp" : "image/webp",
    ".ico" : "image/x-icon",
    ".woff" : "font/woff",
    ".woff2" : "font/woff2",
    ".ttf" : "font/ttf",
    ".eot" : "application/vnd.ms-fontobject",
    ".otf" : "font/otf"
  }
}
