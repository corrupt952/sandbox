require 'rest_client'

class SynchronizingWorker
  include Sidekiq::Worker

  def perform
    client = RestClient::Resource.new(EnvironmentSettings.api.app1_url_base)
    Category.all
      .extend(CategoryRepresenter.for_collection)
      .from_json(client['/categories'].get)
      .each(&:save)
    Post.all
      .extend(PostRepresenter.for_collection)
      .from_json(client['/posts'].get)
      .each(&:save)
  end
end
