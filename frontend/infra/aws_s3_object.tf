resource "aws_s3_object" "static_file" {
  # for_each     = fileset(local.dist_dir, "**")
  for_each     = { for file in fileset(local.dist_dir, "**") : file => file if file != "index.html" }
  bucket       = data.aws_s3_bucket.static_website.id
  key          = each.key
  source       = "${local.dist_dir}/${each.key}"
  content_type = lookup(local.content_types, regex("\\.[^.]+$", each.value), null)
  etag         = filemd5("${local.dist_dir}/${each.value}")
}

resource "aws_s3_object" "website_index" {
  bucket       = data.aws_s3_bucket.static_website.id
  key          = "index.html"
  source       = local_file.index_html.filename
  content_type = "text/html"
}
