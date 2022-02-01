class HomeController < ApplicationController
  def index
    @categories = Category
      .preload(:posts)
  end
end
