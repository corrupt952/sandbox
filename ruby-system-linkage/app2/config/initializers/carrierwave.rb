CarrierWave.configure do |config|
  config.fog_credentials = {
    provider: 'AWS',
    aws_access_key_id: EnvironmentSettings.aws.access_key,
    aws_secret_access_key: EnvironmentSettings.aws.secret_key,
    region: EnvironmentSettings.aws.region
  }

  config.fog_directory = EnvironmentSettings.aws.bucket_name
  config.fog_public = true
end
