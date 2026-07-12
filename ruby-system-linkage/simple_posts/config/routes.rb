Rails.application.routes.draw do
  namespace :api do
    resources :categories, only: [:index]
    resources :posts, only: [:index]
  end
end
