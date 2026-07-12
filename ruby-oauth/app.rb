# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'sinatra/base'
require 'sinatra/reloader'

class Application < Sinatra::Base
  CLIENT_ID = ENV['NOTION_CLIENT_ID']
  CLIENT_SECRET = ENV['NOTION_CLIENT_SECRET']
  REDIRECT_URI = 'http://localhost:3000/callback'

  configure do
    enable :sessions

    set :port, ENV.fetch('PORT', 3000)
    set :bind, ENV.fetch('BIND', '0.0.0.0')

    register Sinatra::Reloader
  end

  def authorization_url
    uri = URI.parse('https://api.notion.com/v1/oauth/authorize')
    uri.query = URI.encode_www_form(
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: 'all'
    )
    uri.to_s
  end

  # Handlers
  get '/login' do
    "<a href=\"#{authorization_url}\">Login with Notion</a>"
  end

  get '/logout' do
    session.clear
    redirect '/'
  end

  get '/' do
    redirect '/login' if session[:access_token].nil?

    uri = URI.parse("https://api.notion.com/v1/users/#{session[:user_id]}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.get(
      uri.path,
      {
        'Authorization' => "Bearer #{session[:access_token]}",
        'Notion-Version' => '2022-06-28',
      }
    )
    results = JSON.parse(response.body)['results']
    user = results.first
    <<~HTML
      Hello, <b>#{user['name']}</b>!
      <br />
      <a href="/logout">Logout</a>
    HTML
  end

  get '/callback' do
    code = params[:code]
    uri = URI.parse('https://api.notion.com/v1/oauth/token')
    bearer_token = Base64.strict_encode64("#{CLIENT_ID}:#{CLIENT_SECRET}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.post(
      uri.path,
      URI.encode_www_form(
        grant_type: 'authorization_code',
        redirect_uri: REDIRECT_URI,
        code: code
      ),
      {
        'Authorization' => "Basic #{bearer_token}",
        'Content-Type' => 'application/x-www-form-urlencoded;charset=UTF-8',
        'Notion-Version' => '2022-06-28',
      }
    )
    session[:access_token] = JSON.parse(response.body)['access_token']
    session[:user_id] = JSON.parse(response.body)['owner']['id']
    redirect '/'
  end
end

Application.run!
