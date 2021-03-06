require 'spec_helper'

module Bosh::Director
  describe PackageCompiler do
    before do
      @cloud = double(:cpi)
      Config.stub(:cloud).and_return(@cloud)

      @blobstore = double(:blobstore)
      Config.stub(:blobstore).and_return(@blobstore)

      @director_job = instance_double('Bosh::Director::Jobs::BaseJob')
      Config.stub(:current_job).and_return(@director_job)
      @director_job.stub(:task_cancelled?).and_return(false)

      @deployment = Models::Deployment.make(name: 'mycloud')
      @config = instance_double('Bosh::Director::DeploymentPlan::CompilationConfig')
      @plan = double('Bosh::Director::DeploymentPlan', compilation: @config, model: @deployment, name: 'mycloud')
      @network = instance_double('Bosh::Director::DeploymentPlan::Network', name: 'default')

      @n_workers = 3
      @config.stub(deployment: @plan,
                   network: @network,
                   env: {},
                   cloud_properties: {},
                   workers: @n_workers,
                   reuse_compilation_vms: false)

      Config.stub(:use_compiled_package_cache?).and_return(false)
      @all_packages = []
    end

    def make(plan)
      PackageCompiler.new(plan)
    end

    def make_package(name, deps = [], version = '0.1-dev')
      package = Models::Package.make(name: name, version: version)
      package.dependency_set = deps
      package.save
      @all_packages << package
      package
    end

    def make_compiled(package, stemcell, sha1 = 'deadbeef',
      blobstore_id = 'deadcafe')
      # A little bit of prep to satisfy dependency keys
      deps = package.dependency_set.map do |dep_name|
        Models::Package.find(name: dep_name)
      end
      task = CompileTask.new(package, stemcell, deps)
      dep_key = task.dependency_key

      Models::CompiledPackage.make(package: package,
                                   dependency_key: dep_key,
                                   stemcell: stemcell,
                                   build: 1,
                                   sha1: sha1,
                                   blobstore_id: blobstore_id)
    end

    def prepare_samples
      @release = instance_double('Bosh::Director::DeploymentPlan::Release',
                                 name: 'cf-release',
                                 model: Models::ReleaseVersion.make)
      @stemcell_a = instance_double('Bosh::Director::DeploymentPlan::Stemcell', model: Models::Stemcell.make)
      @stemcell_b = instance_double('Bosh::Director::DeploymentPlan::Stemcell', model: Models::Stemcell.make)

      @p_common = make_package('common')
      @p_syslog = make_package('p_syslog')
      @p_dea = make_package('dea', %w(ruby common))
      @p_ruby = make_package('ruby', %w(common))
      @p_warden = make_package('warden', %w(common))
      @p_nginx = make_package('nginx', %w(common))
      @p_router = make_package('p_router', %w(ruby common))

      rp_large = double('Bosh::Director::DeploymentPlan::ResourcePool', name: 'large', stemcell: @stemcell_a)

      rp_small = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', name: 'small', stemcell: @stemcell_b)

      @t_dea = instance_double('Bosh::Director::DeploymentPlan::Template', package_models: [@p_dea, @p_nginx, @p_syslog])

      @t_warden = instance_double('Bosh::Director::DeploymentPlan::Template', package_models: [@p_warden])

      @t_nginx = instance_double('Bosh::Director::DeploymentPlan::Template', package_models: [@p_nginx])

      @t_router = instance_double('Bosh::Director::DeploymentPlan::Template', package_models: [@p_router])

      @j_dea = instance_double('Bosh::Director::DeploymentPlan::Job',
                               name: 'dea',
                               release: @release,
                               templates: [@t_dea, @t_warden],
                               resource_pool: rp_large)
      @j_router = instance_double('Bosh::Director::DeploymentPlan::Job',
                                  name: 'router',
                                  release: @release,
                                  templates: [@t_nginx, @t_router, @t_warden],
                                  resource_pool: rp_small)

      @package_set_a = [@p_dea, @p_nginx, @p_syslog, @p_warden, @p_common, @p_ruby]

      @package_set_b = [@p_nginx, @p_common, @p_router, @p_warden, @p_ruby]

      # Dependencies lookup expected!
      @release.should_receive(:get_package_model_by_name).
        with('ruby').at_least(1).times.and_return(@p_ruby)
      @release.should_receive(:get_package_model_by_name).
        with('common').at_least(1).times.and_return(@p_common)
    end

    it "doesn't do anything if there are no packages to compile" do
      prepare_samples

      @plan.stub(:jobs).and_return([@j_dea, @j_router])

      @package_set_a.each do |package|
        cp1 = make_compiled(package, @stemcell_a.model)
        @j_dea.should_receive(:use_compiled_package).with(cp1)
      end

      @package_set_b.each do |package|
        cp2 = make_compiled(package, @stemcell_b.model)
        @j_router.should_receive(:use_compiled_package).with(cp2)
      end

      compiler = make(@plan)
      compiler.compile
      # For @stemcell_a we need to compile:
      # [p_dea, p_nginx, p_syslog, p_warden, p_common, p_ruby] = 6
      # For @stemcell_b:
      # [p_nginx, p_common, p_router, p_ruby, p_warden] = 5
      compiler.compile_tasks_count.should == 6 + 5
      # But they are already compiled!
      compiler.compilations_performed.should == 0
    end

    it 'compiles all packages' do
      prepare_samples

      @plan.stub(:jobs).and_return([@j_dea, @j_router])
      compiler = make(@plan)

      @network.should_receive(:reserve).at_least(@n_workers).times do |reservation|
        reservation.should be_an_instance_of(NetworkReservation)
        reservation.reserved = true
      end

      @network.should_receive(:network_settings).
        exactly(11).times.and_return('network settings')

      net = {'default' => 'network settings'}
      vm_cids = (0..10).map { |i| "vm-cid-#{i}" }
      agents = (0..10).map { instance_double('Bosh::Director::AgentClient') }

      @cloud.should_receive(:create_vm).exactly(6).times.
        with(instance_of(String), @stemcell_a.model.cid, {}, net, nil, {}).
        and_return(*vm_cids[0..5])

      @cloud.should_receive(:create_vm).exactly(5).times.
        with(instance_of(String), @stemcell_b.model.cid, {}, net, nil, {}).
        and_return(*vm_cids[6..10])

      AgentClient.should_receive(:new).exactly(11).times.and_return(*agents)

      vm_metadata_updater = instance_double('Bosh::Director::VmMetadataUpdater', update: nil)
      Bosh::Director::VmMetadataUpdater.stub(build: vm_metadata_updater)
      vm_metadata_updater.should_receive(:update).with(anything, { compiling: 'common'})
      vm_metadata_updater.should_receive(:update).with(anything, hash_including(:compiling)).exactly(10).times

      agents.each do |agent|
        initial_state = {
          'deployment' => 'mycloud',
          'resource_pool' => 'package_compiler',
          'networks' => net
        }

        agent.should_receive(:wait_until_ready)
        agent.should_receive(:apply).with(initial_state)
        agent.should_receive(:compile_package) do |*args|
          name = args[2]
          dot = args[3].rindex('.')
          version, build = args[3][0..dot-1], args[3][dot+1..-1]

          package = Models::Package.find(name: name, version: version)
          args[0].should == package.blobstore_id
          args[1].should == package.sha1

          args[4].should be_a(Hash)

          {
            'result' => {
              'sha1' => "compiled #{package.id}",
              'blobstore_id' => "blob #{package.id}"
            }
          }
        end
      end

      @package_set_a.each do |package|
        compiler.should_receive(:with_compile_lock).with(package.id, @stemcell_a.model.id).and_yield
      end

      @package_set_b.each do |package|
        compiler.should_receive(:with_compile_lock).with(package.id, @stemcell_b.model.id).and_yield
      end

      @j_dea.should_receive(:use_compiled_package).exactly(6).times
      @j_router.should_receive(:use_compiled_package).exactly(5).times

      vm_cids.each do |vm_cid|
        @cloud.should_receive(:delete_vm).with(vm_cid)
      end

      @network.should_receive(:release).at_least(@n_workers).times
      @director_job.should_receive(:task_checkpoint).once

      compiler.compile
      compiler.compilations_performed.should == 11

      @package_set_a.each do |package|
        package.compiled_packages.size.should >= 1
      end

      @package_set_b.each do |package|
        package.compiled_packages.size.should >= 1
      end
    end

    describe 'with reuse_compilation_vms option set' do
      let(:net) { {'default' => 'network settings'} }
      let(:initial_state) {
        {
          'deployment' => 'mycloud',
          'resource_pool' => 'package_compiler',
          'networks' => net
        }
      }

      it 'reuses compilation VMs' do
        prepare_samples
        @plan.stub(:jobs).and_return([@j_dea])

        @config.stub(reuse_compilation_vms: true)

        @network.should_receive(:reserve).at_most(@n_workers).times do |reservation|
          reservation.should be_an_instance_of(NetworkReservation)
          reservation.reserved = true
        end

        @network.should_receive(:network_settings).
          at_most(3).times.and_return('network settings')

        vm_cids = (0..2).map { |i| "vm-cid-#{i}" }
        agents = (0..2).map { instance_double('Bosh::Director::AgentClient') }

        @cloud.should_receive(:create_vm).at_most(3).times.
          with(instance_of(String), @stemcell_a.model.cid, {}, net, nil, {}).
          and_return(*vm_cids)

        AgentClient.should_receive(:new).at_most(3).times.and_return(*agents)

        agents.each do |agent|
          agent.should_receive(:wait_until_ready).at_most(6).times
          agent.should_receive(:apply).with(initial_state).at_most(6).times
          agent.should_receive(:compile_package).at_most(6).times do |*args|
            name = args[2]
            dot = args[3].rindex('.')
            version, build = args[3][0..dot-1], args[3][dot+1..-1]

            package = Models::Package.find(name: name, version: version)
            args[0].should == package.blobstore_id
            args[1].should == package.sha1

            args[4].should be_a(Hash)

            {
              'result' => {
                'sha1' => "compiled #{package.id}",
                'blobstore_id' => "blob #{package.id}"
              }
            }
          end
        end

        @j_dea.should_receive(:use_compiled_package).exactly(6).times

        vm_cids.each do |vm_cid|
          @cloud.should_receive(:delete_vm).at_most(1).times.with(vm_cid)
        end

        @network.should_receive(:release).at_most(@n_workers).times
        @director_job.should_receive(:task_checkpoint).once

        compiler = make(@plan)

        @package_set_a.each do |package|
          compiler.should_receive(:with_compile_lock).with(package.id, @stemcell_a.model.id).and_yield
        end

        compiler.compile
        compiler.compilations_performed.should == 6

        @package_set_a.each do |package|
          package.compiled_packages.size.should >= 1
        end
      end

      it 'cleans up compilation vms if there is a failing compilation' do
        prepare_samples
        @plan.stub(:jobs).and_return([@j_dea])

        @config.stub(reuse_compilation_vms: true)
        @config.stub(workers: 1)

        @network.should_receive(:reserve) do |reservation|
          reservation.should be_an_instance_of(NetworkReservation)
          reservation.reserved = true
        end

        @network.should_receive(:network_settings).and_return('network settings')

        vm_cid = 'vm-cid-1'
        agent = instance_double('Bosh::Director::AgentClient')

        @cloud.should_receive(:create_vm).
          with(instance_of(String), @stemcell_a.model.cid, {}, net, nil, {}).
          and_return(vm_cid)

        AgentClient.should_receive(:new).and_return(agent)

        agent.should_receive(:wait_until_ready)
        agent.should_receive(:apply).with(initial_state)
        agent.should_receive(:compile_package).and_raise(RuntimeError)

        @cloud.should_receive(:delete_vm).with(vm_cid)

        @network.should_receive(:release)

        compiler = make(@plan)
        compiler.stub(:with_compile_lock).and_yield

        expect {
          compiler.compile
        }.to raise_error(RuntimeError)
      end
    end

    describe 'tearing down compilation vms' do
      before do # prepare compilation
        release  = instance_double('Bosh::Director::DeploymentPlan::Release',  name: 'release')
        stemcell = instance_double('Bosh::Director::DeploymentPlan::Stemcell', model: Models::Stemcell.make)
        resource_pool = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', stemcell: stemcell)

        package  = make_package('common')
        template = instance_double('Bosh::Director::DeploymentPlan::Template', package_models: [package])
        job      = instance_double(
          'Bosh::Director::DeploymentPlan::Job',
          name: 'job-with-one-package',
          release: release,
          templates: [template],
          resource_pool: resource_pool,
        )

        @plan.stub(jobs: [job])
      end

      before do # create vm
        @network.stub(:reserve) { |reservation| reservation.reserved = true }
        @network.stub(:network_settings)
        @cloud.stub(:create_vm).and_return('vm-cid-1')
      end

      def self.it_tears_down_vm_exactly_once
        it 'tears down VMs exactly once when RpcTimeout error occurs' do
          # agent raises error
          agent = instance_double('Bosh::Director::AgentClient', apply: nil)
          agent.should_receive(:wait_until_ready).and_raise(RpcTimeout)
          AgentClient.should_receive(:new).and_return(agent)

          # vm is destroyed
          @cloud.should_receive(:delete_vm)
          @network.should_receive(:release)

          compiler = make(@plan)
          compiler.stub(:with_compile_lock).and_yield
          expect { compiler.compile }.to raise_error(RpcTimeout)
        end
      end

      context 'reuse_compilation_vms is true' do
        before { @config.stub(reuse_compilation_vms: true) }
        it_tears_down_vm_exactly_once
      end

      context 'reuse_compilation_vms is false' do
        before { @config.stub(reuse_compilation_vms: false) }
        it_tears_down_vm_exactly_once
      end
    end

    it 'should make sure a parallel deployment did not compile a package already' do
      package = Models::Package.make
      stemcell = Models::Stemcell.make

      task = CompileTask.new(package, stemcell, [])

      compiler = make(@plan)
      callback = nil
      compiler.should_receive(:with_compile_lock).with(package.id, stemcell.id) do |&block|
        callback = block
      end
      compiler.compile_package(task)

      compiled_package = Models::CompiledPackage.make(package: package, stemcell: stemcell, dependency_key: '[]')

      callback.call

      task.compiled_package.should == compiled_package
    end

    describe 'the global blobstore' do
      let(:package) { Models::Package.make }
      let(:stemcell) { Models::Stemcell.make }
      let(:task) { CompileTask.new(package, stemcell, []) }
      let(:compiler) { make(@plan) }
      let(:cache_key) { 'cache key' }

      before do
        package.fingerprint = 'fingerprint'
        package.save
        stemcell.sha1 = 'shawone'
        stemcell.save

        task.dependency_key = '[]'
        task.stub(:cache_key).and_return(cache_key)

        Config.stub(:use_compiled_package_cache?).and_return(true)
      end

      describe '.find_compiled_package' do
        it 'returns compiled package if found in local blobstore' do
          compiled_package = Models::CompiledPackage.make(package: package, stemcell: stemcell, dependency_key: '[]')
          BlobUtil.should_not_receive(:fetch_from_global_cache)
          compiler.find_compiled_package(task).should == compiled_package
        end

        it 'returns nil if could not find compiled package and not using global blobstore' do
          Config.stub(:use_compiled_package_cache?).and_return(false)
          BlobUtil.should_not_receive(:fetch_from_global_cache)
          compiler.find_compiled_package(task).should == nil
        end

        it 'returns nil if compiled_package not found in local or global blobstore' do
          Config.stub(:use_compiled_package_cache?).and_return(true)
          Config.stub(:compiled_package_cache_blobstore).and_return(double('cache', exists?: false))
          compiler.find_compiled_package(task).should == nil
        end

        it 'returns the compiled package from the global blobstore if not found locally' do
          compiled_package = double('compiled package', package: package, stemcell: stemcell, dependency_key: '[]')
          Config.stub(:use_compiled_package_cache?).and_return(true)
          Config.stub(:compiled_package_cache_blobstore).and_return(double('cache', exists?: true))
          BlobUtil.should_receive(:fetch_from_global_cache).with(package, stemcell, cache_key, task.dependency_key).and_return(compiled_package)
          compiler.find_compiled_package(task).should == compiled_package
        end
      end

      it 'should check if compiled package is in global blobstore' do
        callback = nil
        compiler.should_receive(:with_compile_lock).with(package.id, stemcell.id) do |&block|
          callback = block
        end

        BlobUtil.should_receive(:exists_in_global_cache?).with(package, cache_key).and_return(true)
        compiler.stub(:find_compiled_package)
        BlobUtil.should_not_receive(:save_to_global_cache)
        compiler.stub(:prepare_vm)
        Models::CompiledPackage.stub(:create)

        compiler.compile_package(task)
        callback.call
      end

      it 'should save compiled package to global cache if not exists' do
        callback = nil
        compiler.should_receive(:with_compile_lock).with(package.id, stemcell.id) do |&block|
          callback = block
        end

        compiler.stub(:find_compiled_package)
        compiled_package = double('compiled package', package: package, stemcell: stemcell, blobstore_id: 'some blobstore id')
        BlobUtil.should_receive(:exists_in_global_cache?).with(package, cache_key).and_return(false)
        BlobUtil.should_receive(:save_to_global_cache).with(compiled_package, cache_key)
        compiler.stub(:prepare_vm)
        Models::CompiledPackage.stub(:create).and_return(compiled_package)

        compiler.compile_package(task)
        callback.call
      end

      it 'only checks the global cache if Config.use_compiled_package_cache? is set' do
        Config.stub(:use_compiled_package_cache?).and_return(false)

        callback = nil
        compiler.should_receive(:with_compile_lock).with(package.id, stemcell.id) do |&block|
          callback = block
        end

        BlobUtil.should_not_receive(:exists_in_global_cache?)
        BlobUtil.should_not_receive(:save_to_global_cache)
        compiler.stub(:prepare_vm)
        Models::CompiledPackage.stub(:create)

        compiler.compile_package(task)
        callback.call
      end
    end

    describe '#prepare_vm' do
      let(:network) { double('network', name: 'name', network_settings: nil) }
      let(:compilation) do
        config = double('compilation_config')
        config.stub(network: network)
        config.stub(cloud_properties: double('cloud_properties'))
        config.stub(env: double('env'))
        config.stub(workers: 2)
        config
      end
      let(:deployment_plan) { double('Bosh::Director::DeploymentPlan', compilation: compilation, model: 'model') }
      let(:stemcell) { Models::Stemcell.make }
      let(:vm) { Models::Vm.make }
      let(:vm_data) { instance_double('Bosh::Director::VmData', vm: vm) }
      let(:reuser) { instance_double('Bosh::Director::VmReuser') }

      context 'with reuse_compilation_vms' do
        before do
          compilation.stub(reuse_compilation_vms: true)
          VmCreator.stub(create: vm)
          VmReuser.stub(new: reuser)
        end

        it 'should clean up the compilation vm if it failed' do
          compiler = described_class.new(deployment_plan)

          compiler.stub(reserve_network: double('network_reservation'))
          client = instance_double('Bosh::Director::AgentClient')
          client.stub(:wait_until_ready).and_raise(RpcTimeout)
          AgentClient.stub(new: client)

          reuser.stub(get_vm: nil)
          reuser.stub(get_num_vms: 0)
          reuser.stub(add_vm: vm_data)

          reuser.should_receive(:remove_vm).with(vm_data)
          vm_data.should_receive(:release)

          compiler.should_receive(:tear_down_vm).with(vm_data)

          expect {
            compiler.prepare_vm(stemcell) do
              # nothing
            end
          }.to raise_error RpcTimeout
        end
      end
    end
  end
end
