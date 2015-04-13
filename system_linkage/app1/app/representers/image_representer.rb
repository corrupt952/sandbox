require 'roar/json'

module ImageRepresenter
  include Roar::JSON

  self.representation_wrap = :image

  property :original, getter: -> _ { self.file.url }
  property :small, getter: -> _ { self.file.small.url }
  property :medium, getter: -> _ { self.file.medium.url }
  property :large, getter: -> _ { self.file.large.url }
end
