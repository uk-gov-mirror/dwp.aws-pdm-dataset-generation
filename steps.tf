resource "aws_s3_bucket_object" "create-hive-tables" {
  bucket = data.terraform_remote_state.common.outputs.config_bucket.id
  key    = "component/pdm-dataset-generation/create-hive-tables.py"
  content = templatefile("${path.module}/steps/create-hive-tables.py",
    {
      bucket      = data.terraform_remote_state.adg.outputs.published_bucket.id
      secret_name = local.secret_name
      log_path    = "/var/log/pdm/hive-tables-creation.log"
    }
  )
}

resource "aws_s3_bucket_object" "generate_pdm_dataset_script" {
  bucket = data.terraform_remote_state.common.outputs.config_bucket.id
  key    = "component/pdm-dataset-generation/generate_pdm_dataset.py"
  content = templatefile("${path.module}/steps/generate_pdm_dataset.py",
    {
      secret_name        = local.secret_name
      staging_db         = "pdm_dataset_generation_staging"
      published_db       = "pdm_dataset_generation"
      file_location      = "pdm-dataset"
      url                = format("%s/datakey/actions/decrypt", data.terraform_remote_state.crypto.outputs.dks_endpoint[local.environment])
      aws_default_region = "eu-west-2"
      log_path           = "/var/log/pdm/generate-pdm-dataset.log"
    }
  )
}

resource "aws_s3_bucket_object" "hive_setup_sh" {
  bucket = data.terraform_remote_state.common.outputs.config_bucket.id
  key    = "component/pdm-dataset-generation/hive-setup.sh"
  content = templatefile("${path.module}/steps/hive-setup.sh",
    {
      hive-scripts-path    = format("s3://%s/%s", data.terraform_remote_state.common.outputs.config_bucket.id, aws_s3_bucket_object.create-hive-tables.key)
      python_logger        = format("s3://%s/%s", data.terraform_remote_state.common.outputs.config_bucket.id, aws_s3_bucket_object.logger.key)
      generate_pdm_dataset = format("s3://%s/%s", data.terraform_remote_state.common.outputs.config_bucket.id, aws_s3_bucket_object.generate_pdm_dataset_script.key)
    }
  )
}

resource "aws_s3_bucket_object" "logger" {
  bucket  = data.terraform_remote_state.common.outputs.config_bucket.id
  key     = "component/pdm-dataset-generation/logger.py"
  content = file("${path.module}/steps/logger.py")
}

resource "aws_s3_bucket_object" "metrics_setup_sh" {
  bucket = data.terraform_remote_state.common.outputs.config_bucket.id
  key    = "component/pdm-dataset-generation/metrics/metrics-setup.sh"
  content = templatefile("${path.module}/steps/metrics-setup.sh",
    {
      metrics_export_to_s3 = format("s3://%s/%s", data.terraform_remote_state.common.outputs.config_bucket.id, aws_s3_bucket_object.export_to_s3_sh.key)
    }
  )
}

resource "aws_s3_bucket_object" "export_to_s3_sh" {
  bucket = data.terraform_remote_state.common.outputs.config_bucket.id
  key    = "component/pdm-dataset-generation/metrics/export-to-s3.sh"
  content = templatefile("${path.module}/steps/export-to-s3.sh",
    {
      pdm_metrics_path    = format("s3://%s/%s", data.terraform_remote_state.adg.outputs.published_bucket.id, "metrics/pdm-metrics.json")
    }
  )
}
