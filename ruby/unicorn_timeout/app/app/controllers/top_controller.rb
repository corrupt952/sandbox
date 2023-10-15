class TopController < ApplicationController
  def index
    ActiveRecord::Base.transaction do
      Rails.logger.info "START"
      # Unicornのtimeoutが3秒の場合、
      # sleepが4秒だとワーカープロセスはキルされないが、5秒ぐらいになるとキルされる
      sleep 5
      Rails.logger.info "END"
    end

    render json: {
      message: 'Hello, world!'
    }
  end
end
