class ThumbnailUploader < CarrierWave::Uploader::Base
  include CarrierWave::RMagick

  # Choose what kind of storage to use for this uploader:
  # storage :file
  storage :fog

  def store_dir
    "uploads/#{model.class.to_s.underscore}/#{mounted_as}/#{model.id}"
  end

  version :small do
    process resize_to_limit: [640, 360]
  end
  version :medium do
    process resize_to_limit: [1024, 576]
  end
  version :large do
    process resize_to_limit: [1920, 1080]
  end

  def extension_white_list
    %w(jpg jpeg png)
  end
end
