require 'net/ssh'
require 'net/ssh/telnet'

hostname = ENV['RTX_HOSTNAME']
username = ENV['RTX_USERNAME']
password = ENV['RTX_PASSWORD']

ssh_options = {
  host_name: hostname,
  user: username,
  password: password,
  # verbose: :debug,
}
ssh = Net::SSH.start(nil, nil, ssh_options)

telnet = Net::SSH::Telnet.new(
  'Session' => ssh,
  'Prompt' => /^>\s+$/,
)

# http://www.rtpro.yamaha.co.jp/RT/manual/rt-common/setup/console_character.html
telnet.cmd('console character en.ascii')
telnet.cmd('console lines infinity')

puts telnet.cmd('show config')
# puts telnet.cmd('show environment')
