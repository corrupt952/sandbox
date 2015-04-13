class BlogController < ApplicationController
  def index
    @posts = Post
      .ransack(category_slug_eq: params[:slug])
      .result
      .page(params[:page])
      .per(params[:per])
  end

  def show
    @post = Post.find_by(postname: params[:postname])
  end
end
