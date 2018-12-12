class Category < ActiveRecord::Base
  has_many :posts, dependent: :destroy

  validates :name, presence: true, length: { maximum: 64 }, uniqueness: true
  validates :slug, presence: true, length: { maximum: 32 }, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
end
