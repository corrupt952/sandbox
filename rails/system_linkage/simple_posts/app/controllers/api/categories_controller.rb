module Api
  class CategoriesController < ApplicationController
    def index
      render json: Category.all.extend(CategoryRepresenter.for_collection).to_json
    end
  end
end
