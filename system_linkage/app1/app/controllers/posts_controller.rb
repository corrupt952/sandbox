class PostsController < ApplicationController
  before_action :set_post!, only: [:edit, :update, :destroy]

  def index
    @posts = Post
      .preload(:category)
      .page(params[:page])
      .per(params[:per])
  end

  def new
    @post = Post.new
  end

  def create
    @post = Post.new(post_params)

    if @post.save
      redirect_to posts_path
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @post.update(post_params)
      redirect_to posts_path
    else
      render :edit
    end
  end

  def destroy
    @post.destroy
    redirect_to posts_path
  end

  private

  def set_post!
    @post = Post.find(params[:id])
  end

  def post_params
    self.params.require(:post).permit(:id, :category_id, :title, :body, :postname, :thumbnail, :thumbnail_cache)
  end
end
