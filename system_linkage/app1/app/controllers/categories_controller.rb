class CategoriesController < ApplicationController
  before_action :set_category!, only: [:edit, :update, :destroy]

  def index
    @categories = Category
      .preload(:posts)
      .page(params[:page])
      .per(params[:per])
  end

  def new
    @category = Category.new
  end

  def create
    @category = Category.new(category_params)

    if @category.save
      redirect_to categories_path
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      redirect_to categories_path
    else
      render :edit
    end
  end

  def destroy
    @category.destroy
    redirect_to categories_path
  end

  private

  def set_category!
    @category = Category.find(params[:id])
  end

  def category_params
    self.params.require(:category).permit(:id, :name, :slug)
  end
end
