require 'roar/json'

module PostRepresenter
  include Roar::JSON

  self.representation_wrap = :post

  property :id
  property :category_id
  property :postname
  property :title
  property :body
  property :thumbnail,
    getter: -> _ { read_attribute(:thumbnail) },
    setter: -> v, _ { write_attribute(:thumbnail, v) }

  collection_representer class: Post
end
