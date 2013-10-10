require 'spec_helper'

module Bosh::Director
  module DeploymentPlan
    describe Assembler do
      before(:each) do
        @cloud = stub(:Cloud)
        Config.stub(:cloud).and_return(@cloud)
        @deployment_plan = stub(:DeploymentPlan)
        @assembler = Assembler.new(@deployment_plan)
      end

      let(:plan) do
        double(DeploymentPlan)
      end

      let(:compiler) do
        Assembler.new(plan)
      end

      it 'should bind deployment' do
        plan.should_receive(:bind_model)
        compiler.bind_deployment
      end

      it 'should bind releases' do
        r1 = stub(Release)
        r2 = stub(Release)

        plan.should_receive(:releases).and_return([r1, r2])

        r1.should_receive(:bind_model)
        r2.should_receive(:bind_model)

        compiler.should_receive(:with_release_locks).and_yield
        compiler.bind_releases
      end

      it 'should bind existing VMs' do
        vm1 = Models::Vm.make
        vm2 = Models::Vm.make

        plan.stub(:vms).and_return([vm1, vm2])

        compiler.should_receive(:bind_existing_vm).with(vm1, an_instance_of(Mutex))
        compiler.should_receive(:bind_existing_vm).with(vm2, an_instance_of(Mutex))

        compiler.bind_existing_deployment
      end

      it 'should bind resource pools' do
        rp1 = double(ResourcePool)
        rp2 = double(ResourcePool)

        plan.should_receive(:resource_pools).and_return([rp1, rp2])

        rp1.should_receive(:process_idle_vms)
        rp2.should_receive(:process_idle_vms)

        compiler.bind_resource_pools
      end

      it 'should bind stemcells' do
        sc1 = double(Stemcell)
        sc2 = double(Stemcell)

        rp1 = double(ResourcePool, :stemcell => sc1)
        rp2 = double(ResourcePool, :stemcell => sc2)

        plan.should_receive(:resource_pools).and_return([rp1, rp2])

        sc1.should_receive(:bind_model)
        sc2.should_receive(:bind_model)

        compiler.bind_stemcells
      end

      it 'should bind templates' do
        r1 = double(Release)
        r2 = double(Release)

        plan.should_receive(:releases).and_return([r1, r2])

        r1.should_receive(:bind_templates)
        r2.should_receive(:bind_templates)

        compiler.bind_templates
      end

      it 'should bind unallocated VMs' do
        instances = (1..4).map { |i| double(Instance) }

        j1 = double(Job, :instances => instances[0..1])
        j2 = double(Job, :instances => instances[2..3])

        plan.should_receive(:jobs).and_return([j1, j2])

        instances.each do |instance|
          instance.should_receive(:bind_unallocated_vm).ordered
          instance.should_receive(:sync_state_with_db).ordered
        end

        compiler.bind_unallocated_vms
      end

      describe :bind_existing_vm do
        before(:each) do
          @lock = Mutex.new
          @vm = Models::Vm.make(:agent_id => 'foo')
        end

        it 'should bind an instance' do
          instance = Models::Instance.make(:vm => @vm)
          state = { 'state' => 'foo' }
          reservations = { 'foo' => 'reservation' }

          @assembler.should_receive(:get_state).with(@vm).
            and_return(state)
          @assembler.should_receive(:get_network_reservations).
            with(state).and_return(reservations)
          @assembler.should_receive(:bind_instance).
            with(instance, state, reservations)
          @assembler.bind_existing_vm(@vm, @lock)
        end

        it 'should bind an idle vm' do
          state = { 'resource_pool' => { 'name' => 'baz' } }
          reservations = { 'foo' => 'reservation' }
          resource_pool = stub(:ResourcePool)

          @deployment_plan.stub(:resource_pool).with('baz').
            and_return(resource_pool)

          @assembler.should_receive(:get_state).with(@vm).
            and_return(state)
          @assembler.should_receive(:get_network_reservations).
            with(state).and_return(reservations)
          @assembler.should_receive(:bind_idle_vm).
            with(@vm, resource_pool, state, reservations)
          @assembler.bind_existing_vm(@vm, @lock)
        end

        it 'should delete no longer needed vms' do
          state = { 'resource_pool' => { 'name' => 'baz' } }
          reservations = { 'foo' => 'reservation' }

          @deployment_plan.stub(:resource_pool).with('baz').
            and_return(nil)

          @assembler.should_receive(:get_state).with(@vm).
            and_return(state)
          @assembler.should_receive(:get_network_reservations).
            with(state).and_return(reservations)
          @deployment_plan.should_receive(:delete_vm).with(@vm)
          @assembler.bind_existing_vm(@vm, @lock)
        end
      end

      describe :bind_idle_vm do
        before(:each) do
          @network = stub(Network)
          @network.stub(:name).and_return('foo')
          @reservation = stub(:NetworkReservation)
          @resource_pool = stub(:ResourcePool)
          @resource_pool.stub(:name).and_return('baz')
          @resource_pool.stub(:network).and_return(@network)
          @idle_vm = stub(:IdleVm)
          @vm = Models::Vm.make
        end

        it 'should add the existing idle VM' do
          @resource_pool.should_receive(:add_idle_vm).and_return(@idle_vm)
          @idle_vm.should_receive(:vm=).with(@vm)
          @idle_vm.should_receive(:current_state=).with({ 'state' => 'foo' })

          @assembler.bind_idle_vm(
            @vm, @resource_pool, { 'state' => 'foo' }, {})
        end

        it 'should release a static network reservation' do
          @reservation.stub(:static?).and_return(true)

          @resource_pool.should_receive(:add_idle_vm).and_return(@idle_vm)
          @idle_vm.should_receive(:vm=).with(@vm)
          @idle_vm.should_receive(:current_state=).with({ 'state' => 'foo' })
          @network.should_receive(:release).with(@reservation)

          @assembler.bind_idle_vm(
            @vm, @resource_pool, { 'state' => 'foo' }, { 'foo' => @reservation })
        end

        it 'should reuse a valid network reservation' do
          @reservation.stub(:static?).and_return(false)

          @resource_pool.should_receive(:add_idle_vm).and_return(@idle_vm)
          @idle_vm.should_receive(:vm=).with(@vm)
          @idle_vm.should_receive(:current_state=).with({ 'state' => 'foo' })
          @idle_vm.should_receive(:use_reservation).with(@reservation)

          @assembler.bind_idle_vm(
            @vm, @resource_pool, { 'state' => 'foo' }, { 'foo' => @reservation })
        end
      end

      describe :bind_instance do
        before(:each) do
          @model = Models::Instance.make(:job => 'foo', :index => 3)
        end

        it 'should associate the instance to the instance spec' do
          state = { 'state' => 'baz' }
          reservations = { 'net' => 'reservation' }

          instance = stub(Instance)
          resource_pool = stub(:ResourcePool)
          job = stub(Job)
          job.stub(:instance).with(3).and_return(instance)
          job.stub(:resource_pool).and_return(resource_pool)
          @deployment_plan.stub(:job).with('foo').and_return(job)
          @deployment_plan.stub(:job_rename).and_return({})
          @deployment_plan.stub(:rename_in_progress?).and_return(false)

          instance.should_receive(:use_model).with(@model)
          instance.should_receive(:current_state=).with(state)
          instance.should_receive(:take_network_reservations).with(reservations)
          resource_pool.should_receive(:mark_active_vm)

          @assembler.bind_instance(@model, state, reservations)
        end

        it 'should update the instance name if it is being renamed' do
          state = { 'state' => 'baz' }
          reservations = { 'net' => 'reservation' }

          instance = stub(Instance)
          resource_pool = stub(:ResourcePool)
          job = stub(Job)
          job.stub(:instance).with(3).and_return(instance)
          job.stub(:resource_pool).and_return(resource_pool)
          @deployment_plan.stub(:job).with('bar').and_return(job)
          @deployment_plan.stub(:job_rename).
            and_return({ 'old_name' => 'foo', 'new_name' => 'bar' })
          @deployment_plan.stub(:rename_in_progress?).and_return(true)

          instance.should_receive(:use_model).with(@model)
          instance.should_receive(:current_state=).with(state)
          instance.should_receive(:take_network_reservations).with(reservations)
          resource_pool.should_receive(:mark_active_vm)

          @assembler.bind_instance(@model, state, reservations)
        end

        it "should mark the instance for deletion when it's no longer valid" do
          state = { 'state' => 'baz' }
          reservations = { 'net' => 'reservation' }
          @deployment_plan.stub(:job).with('foo').and_return(nil)
          @deployment_plan.should_receive(:delete_instance).with(@model)
          @deployment_plan.stub(:job_rename).and_return({})
          @deployment_plan.stub(:rename_in_progress?).and_return(false)

          @assembler.bind_instance(@model, state, reservations)
        end
      end

      describe :get_network_reservations do
        it 'should reserve all of the networks listed in the state' do
          foo_network = stub(Network)
          bar_network = stub(Network)

          @deployment_plan.stub(:network).with('foo').and_return(foo_network)
          @deployment_plan.stub(:network).with('bar').and_return(bar_network)

          foo_reservation = nil
          foo_network.should_receive(:reserve).and_return do |reservation|
            reservation.ip.should == NetAddr::CIDR.create('1.2.3.4').to_i
            reservation.reserved = true
            foo_reservation = reservation
            true
          end

          bar_network.should_receive(:reserve).and_return do |reservation|
            reservation.ip.should == NetAddr::CIDR.create('10.20.30.40').to_i
            reservation.reserved = false
            false
          end

          @assembler.get_network_reservations({
                                                               'networks' => {
                                                                 'foo' => {
                                                                   'ip' => '1.2.3.4'
                                                                 },
                                                                 'bar' => {
                                                                   'ip' => '10.20.30.40'
                                                                 }
                                                               }
                                                             }).should == { 'foo' => foo_reservation }
        end
      end

      describe :get_state do
        it 'should return the processed agent state' do
          state = { 'state' => 'baz' }

          vm = Models::Vm.make(:agent_id => 'agent-1')
          client = stub(:AgentClient)
          AgentClient.stub(:new).with('agent-1').and_return(client)

          client.should_receive(:get_state).and_return(state)
          @assembler.should_receive(:verify_state).with(vm, state)
          @assembler.should_receive(:migrate_legacy_state).
            with(vm, state)

          @assembler.get_state(vm)
        end
      end

      describe :verify_state do
        before(:each) do
          @deployment = Models::Deployment.make(:name => 'foo')
          @vm = Models::Vm.make(:deployment => @deployment, :cid => 'foo')
          @deployment_plan.stub(:name).and_return('foo')
          @deployment_plan.stub(:model).and_return(@deployment)
        end

        it 'should do nothing when VM is ok' do
          @assembler.verify_state(@vm, { 'deployment' => 'foo' })
        end

        it 'should do nothing when instance is ok' do
          Models::Instance.make(
            :deployment => @deployment, :vm => @vm, :job => 'bar', :index => 11)
          @assembler.verify_state(@vm, {
            'deployment' => 'foo',
            'job' => {
              'name' => 'bar'
            },
            'index' => 11
          })
        end

        it 'should make sure VM and instance belong to the same deployment' do
          other_deployment = Models::Deployment.make
          Models::Instance.make(
            :deployment => other_deployment, :vm => @vm, :job => 'bar',
            :index => 11)
          lambda {
            @assembler.verify_state(@vm, {
              'deployment' => 'foo',
              'job' => { 'name' => 'bar' },
              'index' => 11
            })
          }.should raise_error(VmInstanceOutOfSync,
                               "VM `foo' and instance `bar/11' " +
                                 "don't belong to the same deployment")
        end

        it 'should make sure the state is a Hash' do
          lambda {
            @assembler.verify_state(@vm, 'state')
          }.should raise_error(AgentInvalidStateFormat, /expected Hash/)
        end

        it 'should make sure the deployment name is correct' do
          lambda {
            @assembler.verify_state(@vm, { 'deployment' => 'foz' })
          }.should raise_error(AgentWrongDeployment,
                               "VM `foo' is out of sync: expected to be a part " +
                                 "of deployment `foo' but is actually a part " +
                                 "of deployment `foz'")
        end

        it 'should make sure the job and index exist' do
          lambda {
            @assembler.verify_state(@vm, {
              'deployment' => 'foo',
              'job' => { 'name' => 'bar' },
              'index' => 11
            })
          }.should raise_error(AgentUnexpectedJob,
                               "VM `foo' is out of sync: it reports itself as " +
                                 "`bar/11' but there is no instance reference in DB")
        end

        it 'should make sure the job and index are correct' do
          lambda {
            @deployment_plan.stub(:job_rename).and_return({})
            @deployment_plan.stub(:rename_in_progress?).and_return(false)
            Models::Instance.make(
              :deployment => @deployment, :vm => @vm, :job => 'bar', :index => 11)
            @assembler.verify_state(@vm, {
              'deployment' => 'foo',
              'job' => { 'name' => 'bar' },
              'index' => 22
            })
          }.should raise_error(AgentJobMismatch,
                               "VM `foo' is out of sync: it reports itself as " +
                                 "`bar/22' but according to DB it is `bar/11'")
        end
      end

      describe :migrate_legacy_state
      describe :bind_resource_pools

      describe :bind_instance_networks do
        before(:each) do
          @job_spec = stub(Job)
          @instance_spec = stub(Instance)
          @network_spec = stub(Network)

          @deployment_plan.stub(:jobs).and_return([@job_spec])
          @deployment_plan.stub(:network).with('network-a').
            and_return(@network_spec)

          @job_spec.stub(:name).and_return('job-a')
          @job_spec.stub(:instances).and_return([@instance_spec])

          @network_reservation = NetworkReservation.new(
            :type => NetworkReservation::DYNAMIC)
          @network_reservation.reserved = false

          @instance_spec.stub(:network_reservations).
            and_return({ 'network-a' => @network_reservation })
          @instance_spec.stub(:index).and_return(3)
        end

        it 'should do nothing if the ip is already reserved' do
          @network_reservation.reserved = true
          @assembler.bind_instance_networks
        end

        it 'should make a network reservation' do
          @network_spec.should_receive(:reserve!).
            with(@network_reservation, "`job-a/3'")

          @assembler.bind_instance_networks
        end
      end

      describe :bind_configuration do
        before(:each) do
          @template_spec = stub(:TemplateSpec)
          @job_spec = stub(Job)
          @deployment_plan.stub(:jobs).and_return([@job_spec])
        end

        it 'should bind the configuration hash' do
          configuration_hasher = stub(:ConfigurationHasher)
          configuration_hasher.should_receive(:hash)
          ConfigurationHasher.stub(:new).with(@job_spec).
            and_return(configuration_hasher)
          @assembler.bind_configuration
        end
      end

      describe :bind_dns do
        before(:each) do
          Config.stub(:dns).and_return({ 'address' => '1.2.3.4' })
          Config.stub(:dns_domain_name).and_return('bosh')
        end

        it "should create the domain if it doesn't exist" do
          domain = nil
          @deployment_plan.should_receive(:dns_domain=).
            and_return { |*args| domain = args.first }
          @assembler.bind_dns

          Models::Dns::Domain.count.should == 1
          Models::Dns::Domain.first.should == domain
          domain.name.should == 'bosh'
          domain.type.should == 'NATIVE'
        end

        it 'should reuse the domain if it exists' do
          domain = Models::Dns::Domain.make(:name => 'bosh', :type => 'NATIVE')
          @deployment_plan.should_receive(:dns_domain=).with(domain)
          @assembler.bind_dns

          Models::Dns::Domain.count.should == 1
        end

        it "should create the SOA, NS & A record if they doesn't exist" do
          domain = Models::Dns::Domain.make(:name => 'bosh', :type => 'NATIVE')
          @deployment_plan.should_receive(:dns_domain=)
          @assembler.bind_dns

          Models::Dns::Record.count.should == 3
          records = Models::Dns::Record
          types = records.map { |r| r.type }
          types.should == %w[SOA NS A]
        end

        it 'should reuse the SOA record if it exists' do
          domain = Models::Dns::Domain.make(:name => 'bosh', :type => 'NATIVE')
          soa = Models::Dns::Record.make(:domain => domain, :name => 'bosh',
                                             :type => 'SOA')
          ns = Models::Dns::Record.make(:domain => domain, :name => 'bosh',
                                            :type => 'NS', :content => 'ns.bosh',
                                            :ttl => 14400) # 4h
          a = Models::Dns::Record.make(:domain => domain, :name => 'ns.bosh',
                                           :type => 'A', :content => '1.2.3.4',
                                           :ttl => 14400) # 4h
          @deployment_plan.should_receive(:dns_domain=)
          @assembler.bind_dns

          soa.refresh
          ns.refresh
          a.refresh

          Models::Dns::Record.count.should == 3
          Models::Dns::Record.all.should == [soa, ns, a]
        end
      end

      describe :bind_instance_vms
      describe :bind_instance_vm

      describe :delete_unneeded_vms do
        it 'should delete unneeded VMs' do
          vm = Models::Vm.make(:cid => 'vm-cid')
          @deployment_plan.stub(:unneeded_vms).and_return([vm])

          @cloud.should_receive(:delete_vm).with('vm-cid')
          @assembler.delete_unneeded_vms

          Models::Vm[vm.id].should be_nil
          check_event_log do |events|
            events.size.should == 2
            events.map { |e| e['stage'] }.uniq.should == ['Deleting unneeded VMs']
            events.map { |e| e['total'] }.uniq.should == [1]
            events.map { |e| e['task'] }.uniq.should == %w(vm-cid)
          end
        end
      end

      describe :delete_unneeded_instances do
        it 'should delete unneeded instances' do
          instance = Models::Instance.make
          @deployment_plan.stub(:unneeded_instances).and_return([instance])
          instance_deleter = double('instance_deleter')
          InstanceDeleter.stub(:new).and_return(instance_deleter)

          instance_deleter.should_receive(:delete_instances).with([instance])
          @assembler.delete_unneeded_instances
        end
      end
    end
  end
end
