class Post < ActiveRecord::Base
  belongs_to :category

  mount_uploader :thumbnail, ThumbnailUploader

  validates :category_id, presence: true
  validates :postname, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :title, presence: true
  validates :body, presence: true
  validates :thumbnail, presence: true

  delegate :name, :slug, to: :category, prefix: true
end
