# terraform-archive-file

Verifies zip creation patterns with Terraform's
[`archive_file`](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file)
data source. `data.tf` covers five cases, each writing a zip into `dist/`
(gitignored):

- a single file (`source_file`)
- a directory containing a single file (`source_dir`)
- a directory containing multiple files (`source_dir`)
- a single inline `source` block
- multiple inline `source` blocks

The `archive_dir/` and `archive_dir_single_file/` directories are empty fixture
files used as zip inputs.

## How to run

```sh
terraform init
terraform apply
ls dist/
```

## Notes

- Originally written against Terraform 0.11, but the current code is HCL2 and
  requires Terraform 0.12+. No provider version is pinned.
