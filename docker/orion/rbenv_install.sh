#!/bin/bash
git clone https://github.com/sstephenson/rbenv.git ~/.rbenv
mkdir -p ~/.rbenv/plugins
git clone https://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
echo "export PATH=\"~/.rbenv/bin:~/.rbenv/shims:\$PATH\"" >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile

source ~/.bash_profile
rbenv install 2.2.1
rbenv global 2.2.1
gem install bundler
gem install rails
