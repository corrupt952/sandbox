class ImageUploader < CarrierWave::Uploader::Base
  include CarrierWave::RMagick

  # Choose what kind of storage to use for this uploader:
  # storage :file
  storage :fog

  def store_dir
    "uploads/#{model.class.to_s.underscore}/#{mounted_as}/#{model.id}"
  end

  # Process files as they are uploaded:
  # process :scale => [200, 300]
  #
  # def scale(width, height)
  #   # do something
  # end

  version :small do
    process resize_to_limit: [150, 150]
  end
  version :medium do
    process resize_to_limit: [400, 400]
  end
  version :large do
    process resize_to_limit: [1024, 1024]
  end

  def extension_white_list
    %w(jpg jpeg png)
  end
end
