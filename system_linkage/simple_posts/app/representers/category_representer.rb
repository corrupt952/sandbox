require 'roar/json'

module CategoryRepresenter
  include Roar::JSON

  self.representation_wrap = :category

  property :id
  property :name
  property :slug

  collection_representer class: Category
end
