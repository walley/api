# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|

  ###  FRONTEND  ###################################################
  config.vm.define "frontend" do |frontend|
    frontend.vm.box = "fedora/23-cloud-base"

    frontend.vm.network "forwarded_port", guest: 80, host: 5000

    frontend.vm.synced_folder ".", "/vagrant", type: "rsync", rsync__exclude: ".git/"

    frontend.vm.network "private_network", ip: "192.168.242.51"

    # Update the system
    #frontend.vm.provision "shell",
    #  inline: "sudo dnf -y update"

    # Install package
    frontend.vm.provision "shell",
      inline: "sudo dnf -y install httpd mod_perl sqlite perl-JSON perl-DBI perl-Data-Dumper perl-DBD-SQLite perl-Image-ExifTool perl-App-cpanminus perl-Exporter-Tiny perl-Class-Load perl-Test-Warn perl-Capture-Tiny perl-Sub-Uplevel perl-Moo perl-Package-Stash perl-Devel-StackTrace perl-Test-Most perl-Type-Tiny perl-HTML-Parser perl-HTML-Tagset perl-Socket6 perl-Sys-Syslog perl-libwww-perl"


    # Install unpackaged perl modules
    frontend.vm.provision "shell", inline: <<-EOF
      (echo y;echo o conf prerequisites_policy follow;echo o conf commit)|sudo cpan
      sudo cpanm install 'Geo::JSON'
      sudo cpanm install 'HTML::Entities'
      sudo cpanm install 'Net::Subnet'
    EOF

    # Create directory structure
    frontend.vm.provision "shell", inline: <<-EOF
      #wedonotneedthis sudo mkdir -p /var/www/mapy/ && sudo chown vagrant /var/www/mapy/
      sudo mkdir -p /var/www/api && sudo chown vagrant /var/www/api
      ls -d /var/www/api/handler || sudo ln -s /vagrant/handler /var/www/api/
      #wedonotneedthis ls -d /var/www/mapy/guidepost || sudo ln -s /vagrant/guidepost /var/www/mapy/
    EOF

    # create db
    frontend.vm.provision "shell",
      inline: "ls /vagrant/sqlite-create-schema.sql || sqlite3 /var/www/api/guidepost < /vagrant/sqlite-guidepostdb.sql"
    # fixme, add this  inline: "ls /vagrant/sqlite-create-schema.sql || sqlite3 /var/www/api/commons < /vagrant/sqlite-commons.sql"


    # copy apache config
    frontend.vm.provision "shell", run: "always",
      inline: "sudo cp /vagrant/httpd-api.conf /etc/httpd/conf.d/"

    # Disable selinux
    frontend.vm.provision "shell",
      inline: "sudo setenforce 0"

    # start apache
    frontend.vm.provision "shell", run: "always",
      inline: "service httpd start"

    frontend.vm.provision "shell", run: "always", inline: <<-EOF
      echo "#########################################################"
      echo "###   Your development instance of OSMCZ API          ###"
      echo "###   is now running at: http://localhost:5000        ###"
      echo "#########################################################"
    EOF
  end

end
