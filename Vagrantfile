Vagrant.configure(2) do |config|
    config.vm.provider :virtualbox do |vb|
        vb.memory = 1024
        vb.cpus = 2
    end

    config.vm.box = "ubuntu/xenial64"
    config.vm.box_version = "20180921.0.0"

    config.vm.provider :virtualbox do |vb|
        vb.name = "imaginarycities-test"
    end

    # Provision the VM
    config.vm.provision "shell", inline: <<-SHELL
        echo 'Build Begin' && date

        # Assign a valid hostname
        sed -i 's/^127\.0\.0\.1\t.*/127\.0\.0\.1\tlocalhost imaginarycities imaginarycities.takeo.org/' /etc/hosts
        hostnamectl set-hostname imaginarycities

        # Suppress "dpkg-reconfigure: unable to re-open stdin: No file or directory" warning
        export DEBIAN_FRONTEND=noninteractive

        # Install PostgreSQL repo
        echo 'deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main' >> /etc/apt/sources.list.d/pgdg.list
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

        # Update Apt
        echo 'Update Apt' && date
        apt-get update

        # Install PostgreSQL
        apt-get install -y postgresql-common
        sed -i 's/^\#create\_main\_cluster.*$/create\_main\_cluster \= false/' /etc/postgresql-common/createcluster.conf
        apt-get install -y postgresql-9.4
        pg_createcluster 9.4 takeo
        pg_ctlcluster 9.4 takeo start

        # Install Perl libraries
        apt-get install -y libdbd-pg-perl libimager-perl libtime-modules-perl libwww-perl libyaml-perl

        echo 'Build End' && date
    SHELL

  # Don't share the default vagrant folder
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Mount backrest path for testing
  config.vm.synced_folder ".", "/imaginary-cities"
end
