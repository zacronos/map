Exec {
    path => [ "/bin/", "/sbin/" , "/usr/bin/", "/usr/sbin/" ]
}

group { "puppet":
    ensure => "present",
}

$node_version = '0.12.6'
$ruby_version = 'ruby-2.1.3'

include update
include stdlib
include '::gnupg'
include nginx

#NODE
class { 'nvm_nodejs':
  user    => 'vagrant',
  version => '0.12.6',
  npm_version => '2.12.1'
}

#RVM
class { '::rvm':}#same as include, but allows overrides
#gnupg_key_id => false#, version => stable}
rvm::system_user { www-data: ; vagrant: ;}
rvm_system_ruby {
  $ruby_version:
    ensure      => 'present',
    default_use => true;
}

rvm_gem {
  'foreman':
    name         => 'foreman',
    ruby_version => $ruby_version,
    ensure       => latest,
    require      => Rvm_system_ruby[$ruby_version];
}

#RUN REALTYMAPS APP
class { 'app':
  user    => 'vagrant',
  node_version => $node_version,
  ruby_version =>  $ruby_version
}
