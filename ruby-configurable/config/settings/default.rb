class Settings
  extend Dry::Configurable

  setting :services do
    setting :redis do
      setting :host, 'localhost'
      setting :port, '6389'
    end
  end
end
