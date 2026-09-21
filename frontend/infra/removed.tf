# The static site files are uploaded by .github/workflows/static-deploy.yml
# (`aws s3 sync`, with Cache-Control headers). Terraform used to manage the same
# objects with aws_s3_object, so the two fought over them: every deploy showed up
# as drift here, and an apply would have stripped the headers again.
#
# This forgets the objects (removes them from the state) WITHOUT deleting them.
# `destroy = false` is essential: deleting the resource without it would delete
# the files from the bucket and take the site down.
#
# Once this has been applied, this file can be deleted.
removed {
  from = aws_s3_object.static_file

  lifecycle {
    destroy = false
  }
}
