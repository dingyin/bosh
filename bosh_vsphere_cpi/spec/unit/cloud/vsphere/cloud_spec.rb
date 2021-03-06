require 'spec_helper'

describe VSphereCloud::Cloud do
  let(:config) { { fake: 'config' } }
  let(:client) { double('fake client') }

  subject(:vsphere_cloud) { VSphereCloud::Cloud.new(config) }

  before do
    VSphereCloud::Config.should_receive(:configure).with(config)
    VSphereCloud::Config.stub(client: client)
    VSphereCloud::Cloud.any_instance.stub(:at_exit)
  end

  describe 'has_vm?' do
    let(:vm_id) { 'vm_id' }

    context 'the vm is found' do
      it 'returns true' do
        vsphere_cloud.should_receive(:get_vm_by_cid).with(vm_id)
        expect(vsphere_cloud.has_vm?(vm_id)).to be_true
      end
    end

    context 'the vm is not found' do
      it 'returns false' do
        vsphere_cloud.should_receive(:get_vm_by_cid).with(vm_id).and_raise(Bosh::Clouds::VMNotFound)
        expect(vsphere_cloud.has_vm?(vm_id)).to be_false
      end
    end
  end

  describe 'snapshot_disk' do
    it 'raises not implemented exception when called' do
      expect { vsphere_cloud.snapshot_disk('123') }.to raise_error(Bosh::Clouds::NotImplemented)
    end
  end

  describe '#replicate_stemcell' do
    let(:stemcell_vm) { double('fake local stemcell') }
    let(:stemcell_id) { 'fake_stemcell_id' }

    let(:datacenter) do
      datacenter = double('fake datacenter', name: 'fake_datacenter')
      datacenter.stub_chain(:template_folder, :name).and_return('fake_template_folder')
      datacenter
    end
    let(:cluster) { double('fake cluster', datacenter: datacenter) }
    let(:datastore) { double('fake datastore') }

    context 'when stemcell vm is not found at the expected location' do
      it 'raises an error' do
        client.stub(find_by_inventory_path: nil)

        expect {
          vsphere_cloud.replicate_stemcell(cluster, datastore, 'fake_stemcell_id')
        }.to raise_error(/Could not find stemcell/)
      end
    end

    context 'when stemcell vm resides on a different datastore' do
      before do
        datastore.stub_chain(:mob, :__mo_id__).and_return('fake_datastore_managed_object_id')
        client.stub(:find_by_inventory_path).with(
          [
            cluster.datacenter.name,
            'vm',
            cluster.datacenter.template_folder.name,
            stemcell_id,
          ]
        ).and_return(stemcell_vm)

        client.stub(:get_property).with(stemcell_vm, anything, 'datastore', anything).and_return('fake_stemcell_datastore')
      end

      it 'searches for stemcell on all cluster datastores' do
        client.should_receive(:find_by_inventory_path).with(
          [
            cluster.datacenter.name,
            'vm',
            cluster.datacenter.template_folder.name,
            "#{stemcell_id} %2f #{datastore.mob.__mo_id__}",
          ]
        ).and_return(double('fake stemcell vm'))

        vsphere_cloud.replicate_stemcell(cluster, datastore, stemcell_id)
      end

      context 'when the stemcell replica is not found in the datacenter' do
        let(:replicated_stemcell) { double('fake_replicated_stemcell') }
        let(:fake_task) { 'fake_task' }

        it 'replicates the stemcell' do
          client.stub(:find_by_inventory_path).with(
            [
              cluster.datacenter.name,
              'vm',
              cluster.datacenter.template_folder.name,
              "#{stemcell_id} %2f #{datastore.mob.__mo_id__}",
            ]
          )

          datacenter.stub_chain(:template_folder, :mob).and_return('fake_template_folder_mob')
          cluster.stub_chain(:resource_pool, :mob).and_return('fake_resource_pool_mob')
          stemcell_vm.stub(:clone).with(any_args).and_return(fake_task)
          client.stub(:wait_for_task).with(fake_task).and_return(replicated_stemcell)
          replicated_stemcell.stub(:create_snapshot).with(any_args).and_return(fake_task)

          vsphere_cloud.replicate_stemcell(cluster, datastore, stemcell_id).should eq(replicated_stemcell)
        end
      end
    end

    context 'when stemcell resides on the given datastore' do

      it 'returns the found replica' do
        client.stub(:find_by_inventory_path).with(any_args).and_return(stemcell_vm)
        client.stub(:get_property).with(any_args).and_return(datastore)
        datastore.stub(:mob).and_return(datastore)

        vsphere_cloud.replicate_stemcell(cluster, datastore, stemcell_id).should eq(stemcell_vm)

      end
    end
  end

  describe '#generate_network_env' do
    let(:device) { instance_double('Vim::Vm::Device::VirtualEthernetCard', backing: backing, mac_address: '00:00:00:00:00:00') }
    let(:devices) { [device] }
    let(:network1) {
      {
        'cloud_properties' => {
          'name' => 'fake_network1'
        }
      }
    }
    let(:networks) { { 'fake_network1' => network1 } }
    let(:dvs_index) { {} }
    let(:expected_output) { {
      'fake_network1' => {
        'cloud_properties' => {
          'name' => 'fake_network1'
        },
        'mac' => '00:00:00:00:00:00'
      }
    } }
    let(:path_finder) { instance_double('VSphereCloud::PathFinder') }

    before do
      device.stub(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualEthernetCard) { true }
      VSphereCloud::PathFinder.stub(:new).and_return(path_finder)
      path_finder.stub(:path).with(any_args).and_return('fake_network1')
    end

    context 'using a distributed switch' do
      let(:backing) { instance_double('Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo') }
      let(:dvs_index) { { 'fake_pgkey1' => 'fake_network1' } }

      it 'generates the network env' do
        backing.stub(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo) { true }
        backing.stub_chain(:port, :portgroup_key) { 'fake_pgkey1' }

        expect(vsphere_cloud.generate_network_env(devices, networks, dvs_index)).to eq(expected_output)
      end
    end

    context 'using a standard switch' do
      let(:backing) { double(network: 'fake_network1') }

      it 'generates the network env' do
        backing.stub(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo) { false }

        expect(vsphere_cloud.generate_network_env(devices, networks, dvs_index)).to eq(expected_output)
      end
    end

    context 'passing in device that is not a VirtualEthernetCard' do
      let(:devices) { [device, double()] }
      let(:backing) { double(network: 'fake_network1') }

      it 'ignores non VirtualEthernetCard devices' do
        backing.stub(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo) { false }

        expect(vsphere_cloud.generate_network_env(devices, networks, dvs_index)).to eq(expected_output)
      end
    end

    context 'when the network is in a folder' do

      context 'using a standard switch' do
        let(:path_finder) { instance_double('VSphereCloud::PathFinder') }
        let(:fake_network_object) { double() }
        let(:backing) { double(network: fake_network_object) }
        let(:network1) {
          {
            'cloud_properties' => {
              'name' => 'networks/fake_network1'
            }
          }
        }
        let(:networks) { { 'networks/fake_network1' => network1 } }
        let(:expected_output) { {
          'networks/fake_network1' => {
            'cloud_properties' => {
              'name' => 'networks/fake_network1'
            },
            'mac' => '00:00:00:00:00:00'
          }
        } }

        it 'generates the network env' do
          VSphereCloud::PathFinder.stub(:new).and_return(path_finder)
          path_finder.stub(:path).with(fake_network_object).and_return('networks/fake_network1')

          backing.stub(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo) { false }

          expect(vsphere_cloud.generate_network_env(devices, networks, dvs_index)).to eq(expected_output)
        end
      end

    end

  end

  describe '#create_nic_config_spec' do
    let(:dvs_index) { {} }

    context 'using a distributed switch' do
      let(:v_network_name) { 'fake_network1' }
      let(:network) { instance_double('Vim::Dvs::DistributedVirtualPortgroup', class: VimSdk::Vim::Dvs::DistributedVirtualPortgroup) }
      let(:dvs_index) { {} }
      let(:switch) { double() }
      let(:portgroup_properties) { { 'config.distributedVirtualSwitch' => switch, 'config.key' => 'fake_portgroup_key' } }

      before do
        client.stub(:get_properties).with(network, VimSdk::Vim::Dvs::DistributedVirtualPortgroup,
                                          ['config.key', 'config.distributedVirtualSwitch'],
                                          ensure_all: true).and_return(portgroup_properties)

        client.stub(:get_property).with(switch, VimSdk::Vim::DistributedVirtualSwitch,
                                        'uuid', ensure_all: true).and_return('fake_switch_uuid')
      end

      it 'sets correct port in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        port = device_config_spec.device.backing.port
        expect(port.switch_uuid).to eq('fake_switch_uuid')
        expect(port.portgroup_key).to eq('fake_portgroup_key')
      end

      it 'sets correct backing in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        backing = device_config_spec.device.backing
        expect(backing).to be_a(VimSdk::Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo)
      end

      it 'adds record to dvs_index for portgroup_key' do
        vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        expect(dvs_index['fake_portgroup_key']).to eq('fake_network1')
      end

      it 'sets correct device in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        device = device_config_spec.device
        expect(device.key).to eq(-1)
        expect(device.controller_key).to eq('fake_controller_key')
      end

      it 'sets correct operation in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        expect(device_config_spec.operation).to eq(VimSdk::Vim::Vm::Device::VirtualDeviceSpec::Operation::ADD)
      end
    end

    context 'using a standard switch' do
      let(:v_network_name) { 'fake_network1' }
      let(:network) { double(name: v_network_name) }
      let(:dvs_index) { {} }

      it 'sets correct backing in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        backing = device_config_spec.device.backing
        expect(backing).to be_a(VimSdk::Vim::Vm::Device::VirtualEthernetCard::NetworkBackingInfo)
        expect(backing.device_name).to eq(v_network_name)
      end

      it 'sets correct device in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        device = device_config_spec.device
        expect(device.key).to eq(-1)
        expect(device.controller_key).to eq('fake_controller_key')
      end

      it 'sets correct operation in device config spec' do
        device_config_spec = vsphere_cloud.create_nic_config_spec(v_network_name, network, 'fake_controller_key', dvs_index)

        expect(device_config_spec.operation).to eq(VimSdk::Vim::Vm::Device::VirtualDeviceSpec::Operation::ADD)
      end
    end
  end
end
