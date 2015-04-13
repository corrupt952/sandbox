Rails.application.routes.draw do
  root 'home#index'

  resources :categories, expect: [:show]
  resources :posts, expect: [:show]

  resources :images, only: [:index, :create, :destroy]
end
