class ImagesController < ApplicationController
  def index
    @images = Image.all.page(params[:page]).per(params[:per])
  end

  def create
    image = Image.new(image_params)

    if image.save
      render json: image.extend(ImageRepresenter).to_json
    else
      render nothing: true, status: 500
    end
  end

  def destroy
    Image.find(params[:id]).destroy
    redirect_to images_path
  end

  private

  def image_params
    params.require(:image).permit(:file)
  end
end
