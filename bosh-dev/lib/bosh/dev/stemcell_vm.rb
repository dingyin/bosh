module Bosh::Dev
  class StemcellVm
    def initialize(options, env)
      @vm_name = options.fetch(:vm_name)
      @infrastructure_name = options.fetch(:infrastructure_name)
      @operating_system_name = options.fetch(:operating_system_name)
      @env = env
    end

    def publish
      Rake::FileUtilsExt.sh <<-BASH
        set -eu

        cd bosh-stemcell
        [ -e .vagrant/machines/remote/aws/id ] && vagrant destroy #{vm_name} --force
        vagrant up #{vm_name} --provider #{provider}

        time vagrant ssh -c "
          set -eu
          cd /bosh
          bundle install --local

          #{exports.join("\n          ")}

          time bundle exec rake ci:publish_stemcell[#{infrastructure_name},#{operating_system_name}]
        " #{vm_name}
      BASH
    ensure
      Rake::FileUtilsExt.sh <<-BASH
        set -eu
        cd bosh-stemcell
        vagrant destroy #{vm_name} --force
      BASH
    end

    private

    attr_reader :vm_name, :infrastructure_name, :operating_system_name, :env

    def provider
      case vm_name
        when 'remote' then 'aws'
        when 'local' then 'virtualbox'
        else raise "vm_name must be 'local' or 'remote'"
      end
    end

    def exports
      exports = []

      exports += %w[
        CANDIDATE_BUILD_NUMBER
        BOSH_AWS_ACCESS_KEY_ID
        BOSH_AWS_SECRET_ACCESS_KEY
        AWS_ACCESS_KEY_ID_FOR_STEMCELLS_JENKINS_ACCOUNT
        AWS_SECRET_ACCESS_KEY_FOR_STEMCELLS_JENKINS_ACCOUNT
      ].map do |env_var|
        "export #{env_var}='#{env.fetch(env_var)}'"
      end

      exports += %w[
        UBUNTU_ISO
      ].map do |env_var|
        "export #{env_var}='#{env.fetch(env_var)}'" if env.has_key?(env_var)
      end.compact

      exports
    end
  end
end
