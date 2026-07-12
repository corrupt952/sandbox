data "archive_file" "archive_file" {
  type        = "zip"
  source_file = "${path.module}/data.tf"
  output_path = "${path.module}/dist/archive_file.zip"
}

data "archive_file" "archive_dir_single_file" {
  type        = "zip"
  source_dir  = "${path.module}/archive_dir_single_file"
  output_path = "${path.module}/dist/archive_dir_single_file.zip"
}

data "archive_file" "archive_dir" {
  type        = "zip"
  source_dir  = "${path.module}/archive_dir"
  output_path = "${path.module}/dist/archive_dir.zip"
}

data "archive_file" "archive_source" {
  type        = "zip"
  output_path = "${path.module}/dist/archive_source.zip"

  source {
    filename = "file1"
    content  = "# Archive source"
  }
}

data "archive_file" "archive_sources" {
  type        = "zip"
  output_path = "${path.module}/dist/archive_sources.zip"

  source {
    filename = "file1"
    content  = "# Archive sources"
  }

  source {
    filename = "file2"
    content  = "content"
  }
}
