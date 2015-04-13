class EnvironmentSettings < Settingslogic
  source Rails.root.join('config', 'environment.yml')
  namespace Rails.env
end
