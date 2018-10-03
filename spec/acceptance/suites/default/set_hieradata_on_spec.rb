require 'spec_helper_acceptance'

hosts.each do |host|
  describe '#set_hieradata_on' do
    context 'when passed a YAML string' do
      before(:all) { set_hieradata_on(host, "---\n") }
      after(:all) { on(host, "rm -rf #{host.puppet['hiera_config']} #{hiera_datadir(host)}") }

      it 'creates the datadir' do
        on host, "test -d #{hiera_datadir(host)}"
      end

      it 'writes to the configuration file' do
        stdout = on(host, "cat #{host.puppet['hiera_config']}").stdout
        expect(stdout).to match("hierarchy:\n- name: Common data\n  path: common.yaml")
      end

      it 'writes the correct contents to the correct file' do
        stdout = on(host, "cat #{hiera_datadir(host)}/common.yaml").stdout
        expect(stdout).to eq("---\n")
      end
    end

    context 'when passed a hash' do
      before(:all) { set_hieradata_on(host, { 'foo' => 'bar' }) }
      after(:all) { on(host, "rm -rf #{host.puppet['hiera_config']} #{hiera_datadir(host)}") }

      it 'creates the datadir' do
        on host, "test -d #{hiera_datadir(host)}"
      end

      it 'writes the correct contents to the correct file' do
        stdout = on(host, "cat #{hiera_datadir(host)}/common.yaml").stdout
        expect(stdout).to eq("---\nfoo: bar\n")
      end
    end

    context 'when the terminus is set' do
      before(:all) { set_hieradata_on(
        host,
        {'hiera' => 'key'},
        [{'name' => 'default', 'path' => 'default.yaml'}]
      ) }
      after(:all) { on(host, "rm -rf #{host.puppet['hiera_config']} #{hiera_datadir(host)}") }

      it 'creates the datadir' do
        on host, "test -d #{hiera_datadir(host)}"
      end

      it 'writes the correct hierarchy to the configuration file' do
        stdout = on(host, "cat #{host.puppet['hiera_config']}").stdout
        expect(stdout).to match("hierarchy:\n- name: default\n  path: default.yaml")
      end

      it 'writes the correct contents to the correct file' do
        stdout = on(host, "cat #{hiera_datadir(host)}/default.yaml").stdout
        expect(stdout).to eq("---\nhiera: key")
      end
    end
  end
end
