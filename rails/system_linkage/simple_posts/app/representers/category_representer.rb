require 'roar/json'

module CategoryRepresenter
  include Roar::JSON

  self.representation_wrap = :category

  property :id
  property :name
  property :slug

  collection_representer class: Category, parse_strategy: -> fragment, *args {
      categories = args.last.represented
      categories.find_or_initialize_by(id: fragment['category']['id'])
    }
end
