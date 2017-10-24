Vagrant.configure(2) do |config|
    config.vm.provider :virtualbox do |vb|
        vb.memory = 2048
        vb.cpus = 4
    end

    config.vm.box = "ubuntu/trusty64"
    config.vm.box_version = "20170313.0.7"

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

        # Update Apt
        echo 'Update Apt' && date
        apt-get update

        # Install Perl libraries
        apt-get install -y libimager-perl libtime-modules-perl libyaml-perl

        echo 'Build End' && date
    SHELL

  # Don't share the default vagrant folder
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Mount backrest path for testing
  config.vm.synced_folder ".", "/imaginary-cities"
end
