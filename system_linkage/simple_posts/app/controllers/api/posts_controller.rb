module Api
  class PostsController < ApplicationController
    def index
      render json: Post.all.extend(PostRepresenter.for_collection).to_json.html_safe
    end
  end
end
