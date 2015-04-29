#!/bin/bash

shopt -s expand_aliases
alias cutcut="cut -d',' -f2 | cut -d' ' -f3 | head -n 1"
if [ `uname` = "Darwin" ]; then
    alias echo='/bin/echo'
fi
if [ -d ~/.nvm ]; then
    echo "Exists nvm!"
    echo -n "Can I delete it?(y/N)> "
    read ans

    if [ $ans = "y" ] || [ $ans = "Y" ]; then
        rm -rf ~/.nvm
    else
        exit 1
    fi
fi

git clone git://github.com/creationix/nvm ~/.nvm

cat <<EOT >> ~/.bash_profile
# nvm setting
if [ -e ~/.nvm/nvm.sh ]; then
    source ~/.nvm/nvm.sh
    [[ -r ~/.nvm/bash_completion ]] && . ~/.nvm/bash_completion
fi
EOT

source ~/.nvm/nvm.sh
nvm install $NODE_VERSION
nvm use $NODE_VERSION
nvm alias default $NODE_VERSION
nvm alias stable $NODE_VERSION
