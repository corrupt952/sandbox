require 'sidekiq/web'

Rails.application.routes.draw do
  mount Sidekiq::Web, at: '/sidekiq'

  root 'blog#index'
  get '/:slug', to: 'blog#index', constraints: { slug: /[a-z0-9_-]+/ }, as: :category
  get '/:slug/:postname', to: 'blog#show', constraints: { slug: /[a-z0-9_-]+/, postname: /[a-z0-9_-]+/ }, as: :post
end
