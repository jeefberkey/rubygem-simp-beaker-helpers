require 'beaker-puppet'

module Simp; end

module Simp::BeakerHelpers
  include BeakerPuppet

  require 'simp/beaker_helpers/version'
  require 'simp/beaker_helpers/inspec'
  require 'simp/beaker_helpers/ssg'

  # Stealing this from the Ruby 2.5 Dir::Tmpname workaround from Rails
  def self.tmpname
    t = Time.new.strftime("%Y%m%d")
    "simp-beaker-helpers-#{t}-#{$$}-#{rand(0x100000000).to_s(36)}.tmp"
  end

  # This is the *oldest* version that the latest release of SIMP supports
  #
  # This is done so that we know if some new thing that we're using breaks the
  # oldest system that we support.
  DEFAULT_PUPPET_AGENT_VERSION = '1.10.4'

  # We can't cache this because it may change during a run
  def fips_enabled(sut)
    return on( sut,
              'cat /proc/sys/crypto/fips_enabled 2>/dev/null',
              :accept_all_exit_codes => true
             ).output.strip == '1'
  end

  # Figure out the best method to copy files to a host and use it
  #
  # Will create the directories leading up to the target if they don't exist
  def copy_to(sut, src, dest, opts={})
    unless fips_enabled(sut) || @has_rsync
      %x{which rsync 2>/dev/null}.strip

      @has_rsync = !$?.nil? && $?.success?
    end

    sut.mkdir_p(File.dirname(dest))

    if sut[:hypervisor] == 'docker'
      exclude_list = []
      if opts.has_key?(:ignore) && !opts[:ignore].empty?
        opts[:ignore].each do |value|
          exclude_list << "--exclude '#{value}'"
        end
      end

      %x(tar #{exclude_list.join(' ')} -hcf - -C "#{File.dirname(src)}" "#{File.basename(src)}" | docker exec -i "#{sut.host_hash[:docker_container].id}" tar -C "#{dest}" -xf -)
    elsif @has_rsync && sut.check_for_command('rsync')
      # This makes rsync_to work like beaker and scp usually do
      exclude_hack = %(__-__' -L --exclude '__-__)

      # There appears to be a single copy of 'opts' that gets passed around
      # through all of the different hosts so we're going to make a local deep
      # copy so that we don't destroy the world accidentally.
      _opts = Marshal.load(Marshal.dump(opts))
      _opts[:ignore] ||= []
      _opts[:ignore] << exclude_hack

      if File.directory?(src)
        dest = File.join(dest, File.basename(src)) if File.directory?(src)
        sut.mkdir_p(dest)
      end

      # End rsync hackery

      rsync_to(sut, src, dest, _opts)
    else
      scp_to(sut, src, dest, opts)
    end
  end

  # use the `puppet fact` face to look up facts on an SUT
  def pfact_on(sut, fact_name)
    facts_json = on(sut,'puppet facts find xxx').output
    facts      = JSON.parse(facts_json).fetch( 'values' )
    facts.fetch(fact_name)
  end

  # Returns the modulepath on the SUT, as an Array
  def puppet_modulepath_on(sut, environment='production')
    sut.puppet['modulepath'].split(':')
  end

  # Return the path to the 'spec/fixtures' directory
  def fixtures_path
    STDERR.puts '  ** fixtures_path' if ENV['BEAKER_helpers_verbose']
    dir = RSpec.configuration.default_path
    dir = File.join('.', 'spec') unless dir

    dir = File.join(File.expand_path(dir), 'fixtures')

    if File.directory?(dir)
      return dir
    else
      raise("Could not find fixtures directory at '#{dir}'")
    end
  end

  # Locates .fixture.yml in or above this directory.
  def fixtures_yml_path
    STDERR.puts '  ** fixtures_yml_path' if ENV['BEAKER_helpers_verbose']

    if ENV['FIXTURES_YML']
      fixtures_yml = ENV['FIXTURES_YML']
    else
      fixtures_yml = ''
      dir          = '.'
      while( fixtures_yml.empty? && File.expand_path(dir) != '/' ) do
        file = File.expand_path( '.fixtures.yml', dir )
        STDERR.puts "  ** fixtures_yml_path: #{file}" if ENV['BEAKER_helpers_verbose']
        if File.exists? file
          fixtures_yml = file
          break
        end
        dir = "#{dir}/.."
      end
    end

    raise 'ERROR: cannot locate .fixtures.yml!' if fixtures_yml.empty?

    STDERR.puts "  ** fixtures_yml_path:finished (file: '#{file}')" if ENV['BEAKER_helpers_verbose']

    fixtures_yml
  end


  # returns an Array of puppet modules declared in .fixtures.yml
  def pupmods_in_fixtures_yml
    STDERR.puts '  ** pupmods_in_fixtures_yml' if ENV['BEAKER_helpers_verbose']
    fixtures_yml = fixtures_yml_path
    data         = YAML.load_file( fixtures_yml )
    repos        = data.fetch('fixtures').fetch('repositories', {}).keys || []
    symlinks     = data.fetch('fixtures').fetch('symlinks', {}).keys     || []
    STDERR.puts '  ** pupmods_in_fixtures_yml: finished' if ENV['BEAKER_helpers_verbose']
    (repos + symlinks)
  end


  # Ensures that the fixture modules (under `spec/fixtures/modules`) exists.
  # if any fixture modules are missing, run 'rake spec_prep' to populate the
  # fixtures/modules
  def ensure_fixture_modules
    STDERR.puts "  ** ensure_fixture_modules" if ENV['BEAKER_helpers_verbose']
    unless ENV['BEAKER_spec_prep'] == 'no'
      puts "== checking prepped modules from .fixtures.yml"
      puts "  -- (use BEAKER_spec_prep=no to disable)"
      missing_modules = []
      pupmods_in_fixtures_yml.each do |pupmod|
        STDERR.puts "  **  -- ensure_fixture_modules: '#{pupmod}'" if ENV['BEAKER_helpers_verbose']
        mod_root = File.expand_path( "spec/fixtures/modules/#{pupmod}", File.dirname( fixtures_yml_path ))
        missing_modules << pupmod unless File.directory? mod_root
      end
      puts "  -- #{missing_modules.size} modules need to be prepped"
      unless missing_modules.empty?
        cmd = 'bundle exec rake spec_prep'
        puts "  -- running spec_prep: '#{cmd}'"
        %x(#{cmd})
      else
        puts "  == all fixture modules present"
      end
    end
    STDERR.puts "  **  -- ensure_fixture_modules: finished" if ENV['BEAKER_helpers_verbose']
  end


  # Copy the local fixture modules (under `spec/fixtures/modules`) onto each SUT
  def copy_fixture_modules_to( suts = hosts, opts = {})
    ensure_fixture_modules

    opts[:pluginsync] = opts.fetch(:pluginsync, true)

    unless ENV['BEAKER_copy_fixtures'] == 'no'
      parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
      block_on(suts, :run_in_parallel => parallel) do |sut|
        STDERR.puts "  ** copy_fixture_modules_to: '#{sut}'" if ENV['BEAKER_helpers_verbose']

        # Use spec_prep to provide modules (this supports isolated networks)
        unless ENV['BEAKER_use_fixtures_dir_for_modules'] == 'no'

          # NOTE: As a result of BKR-723, which does not look easy to fix, we
          # cannot rely on `copy_module_to()` to choose a sane default for
          # `target_module_path`.  This workaround queries each SUT's
          # `modulepath` and targets the first one.
          target_module_path = puppet_modulepath_on(sut).first

          mod_root = File.expand_path( "spec/fixtures/modules", File.dirname( fixtures_yml_path ))

          Dir.chdir(mod_root) do
            begin
              tarfile = "#{Simp::BeakerHelpers.tmpname}.tar"

              excludes = PUPPET_MODULE_INSTALL_IGNORE.map do |x|
                x = "--exclude '*/#{x}'"
              end.join(' ')

              %x(tar -ch #{excludes} -f #{tarfile} *)

              if File.exist?(tarfile)
                copy_to(sut, tarfile, target_module_path, opts)
              else
                fail("Error: module tar file '#{tarfile}' could not be created at #{mod_root}")
              end

              on(sut, "cd #{target_module_path} && tar -xf #{File.basename(tarfile)}")
            ensure
              FileUtils.remove_entry(tarfile, true)
            end
          end
        end
      end
    end
    STDERR.puts '  ** copy_fixture_modules_to: finished' if ENV['BEAKER_helpers_verbose']

    # sync custom facts from the new modules to each SUT's factpath
    pluginsync_on(suts) if opts[:pluginsync]
  end


  # Configure and reboot SUTs into FIPS mode
  def enable_fips_mode_on( suts = hosts )
    puts '== configuring FIPS mode on SUTs'
    puts '  -- (use BEAKER_fips=no to disable)'
    parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
    block_on(suts, :run_in_parallel => parallel) do |sut|
      puts "  -- enabling FIPS on '#{sut}'"

      # We need to use FIPS compliant algorithms and keylengths as per the FIPS
      # certification.
      on(sut, 'puppet config set digest_algorithm sha256')
      on(sut, 'puppet config set keylength 2048')

      # We need to be able to get back into our system!
      # Make these safe for all systems, even old ones.
      # TODO Use simp-ssh Puppet module appropriately (i.e., in a fashion
      #      that doesn't break vagrant access and is appropriate for
      #      typical module tests.)
      fips_ssh_ciphers = [ 'aes256-cbc','aes192-cbc','aes128-cbc']
      on(sut, %(sed -i '/Ciphers /d' /etc/ssh/sshd_config))
      on(sut, %(echo 'Ciphers #{fips_ssh_ciphers.join(',')}' >> /etc/ssh/sshd_config))

      fips_enable_modulepath = ''

      if pupmods_in_fixtures_yml.include?('fips')
        copy_fixture_modules_to(sut)
      else
        # If we don't already have the simp-fips module installed
        #
        # Use the simp-fips Puppet module to set FIPS up properly:
        # Download the appropriate version of the module and its dependencies from PuppetForge.
        # TODO provide a R10k download option in which user provides a Puppetfile
        # with simp-fips and its dependencies
        on(sut, 'mkdir -p /root/.beaker_fips/modules')

        fips_enable_modulepath = '--modulepath=/root/.beaker_fips/modules'

        module_install_cmd = 'puppet module install simp-fips --target-dir=/root/.beaker_fips/modules'

        if ENV['BEAKER_fips_module_version']
          module_install_cmd += " --version #{ENV['BEAKER_fips_module_version']}"
        end

        on(sut, module_install_cmd)
      end

      # Enable FIPS and then reboot to finish.
      on(sut, %(puppet apply --verbose #{fips_enable_modulepath} -e "class { 'fips': enabled => true }"))
      sut.reboot
    end
  end


  # Collect all 'yum_repos' entries from the host nodeset.
  # The acceptable format is as follows:
  # yum_repos:
  #   <repo_name>:
  #     url: <URL>
  #     gpgkeys:
  #       - <URL to GPGKEY1>
  #       - <URL to GPGKEY2>
  def enable_yum_repos_on( suts = hosts )
    repo_attrs = [
      :assumeyes,
      :bandwidth,
      :cost,
      :deltarpm_metadata_percentage,
      :deltarpm_percentage,
      :descr,
      :enabled,
      :enablegroups,
      :exclude,
      :failovermethod,
      :gpgcakey,
      :gpgcheck,
      :http_caching,
      :include,
      :includepkgs,
      :keepalive,
      :metadata_expire,
      :metalink,
      :mirrorlist,
      :mirrorlist_expire,
      :priority,
      :protect,
      :provider,
      :proxy,
      :proxy_password,
      :proxy_username,
      :repo_gpgcheck,
      :retries,
      :s3_enabled,
      :skip_if_unavailable,
      :sslcacert,
      :sslclientcert,
      :sslclientkey,
      :sslverify,
      :target,
      :throttle,
      :timeout
    ]

    parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
    block_on(suts, :run_in_parallel => parallel) do |sut|
      if sut['yum_repos']
        sut['yum_repos'].each_pair do |repo, metadata|
          repo_manifest = %(yumrepo { #{repo}:)

          repo_manifest_opts = []

          # Legacy Support
          urls = !metadata[:url].nil? ? metadata[:url] : metadata[:baseurl]
          if urls
            repo_manifest_opts << 'baseurl => ' + '"' + Array(urls).flatten.join('\n        ').gsub('$','\$') + '"'
          end

          # Legacy Support
          gpgkeys = !metadata[:gpgkeys].nil? ? metadata[:gpgkeys] : metadata[:gpgkey]
          if gpgkeys
            repo_manifest_opts << 'gpgkey => ' + '"' + Array(gpgkeys).flatten.join('\n       ').gsub('$','\$') + '"'
          end

          repo_attrs.each do |attr|
            if metadata[attr]
              repo_manifest_opts << "#{attr} => '#{metadata[attr]}'"
            end
          end

          repo_manifest = repo_manifest + %(\n#{repo_manifest_opts.join(",\n")}) + "\n}"

          apply_manifest_on(sut, repo_manifest, :catch_failures => true)
        end
      end
    end
  end

  # Apply known OS fixes we need to run Beaker on each SUT
  def fix_errata_on( suts = hosts )
    parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
    block_on(suts, :run_in_parallel => parallel) do |sut|
      # We need to be able to flip between server and client without issue
      on sut, 'puppet resource group puppet gid=52'
      on sut, 'puppet resource user puppet comment="Puppet" gid="52" uid="52" home="/var/lib/puppet" managehome=true'

      # SIMP uses a central ssh key location, but some keys are only home dirs
      on(sut, "mkdir -p /etc/ssh/local_keys")
      on(sut, "for path in `find / -wholename '/home/*/.ssh/authorized_keys'`;"\
              "do echo $path; user=`ls -l $path | awk '{print $3}'`;"\
              "echo $user; cp --preserve=all -f $path /etc/ssh/local_keys/$user; done")
      on(sut, "if [ -f /root/.ssh/authorized_keys ]; then cp --preserve=all -f /root/.ssh/authorized_keys /etc/ssh/local_keys/root; fi")
      on(sut, "chown -R root:root /etc/ssh/local_keys")
      on(sut, "chmod 644 /etc/ssh/local_keys/*")

      # SIMP uses structured facts, therefore stringify_facts must be disabled
      unless ENV['BEAKER_stringify_facts'] == 'yes'
        on sut, 'puppet config set stringify_facts false'
      end

      # Occasionally we run across something similar to BKR-561, so to ensure we
      # at least have the host defaults:
      #
      # :hieradatadir is used as a canary here; it isn't the only missing key
      unless sut.host_hash.key? :hieradatadir
        configure_type_defaults_on(sut)
      end

      if fact_on(sut, 'osfamily') == 'RedHat'
        enable_yum_repos_on(sut)

        # net-tools required for netstat utility being used by be_listening
        if fact_on(sut, 'operatingsystemmajrelease') == '7'
          pp = <<-EOS
            package { 'net-tools': ensure => installed }
          EOS
          apply_manifest_on(sut, pp, :catch_failures => false)
        end

        # Clean up YUM prior to starting our test runs.
        on(sut, 'yum clean all')
      end
    end

    # Configure and reboot SUTs into FIPS mode
    if ENV['BEAKER_fips'] == 'yes'
      enable_fips_mode_on(suts)
    end
  end


  # Generate a fake openssl CA + certs for each host on a given SUT
  #
  # The directory structure is the same as what FakeCA drops into keydist/
  #
  # NOTE: This generates everything within an SUT and copies it back out.
  #       This is because it is assumed the SUT will have the appropriate
  #       openssl in its environment, which may not be true of the host.
  def run_fake_pki_ca_on( ca_sut = master, suts = hosts, local_dir = '' )
    puts "== Fake PKI CA"
    pki_dir  = File.expand_path( "../../files/pki", File.dirname(__FILE__))
    host_dir = '/root/pki'

    ca_sut.mkdir_p(host_dir)
    Dir[ File.join(pki_dir, '*') ].each{|f| copy_to( ca_sut, f, host_dir)}

    # Collect network information from all SUTs
    #
    # We need this so that we don't insert any common IP addresses into certs
    suts_network_info = {}

    hosts.each do |host|
      fqdn = fact_on(host, 'fqdn').strip

      host_entry = { fqdn => [] }

      # Ensure that all interfaces are active prior to collecting data
      activate_interfaces(host) unless ENV['BEAKER_no_fix_interfaces']

      # Gather the IP Addresses for the host to embed in the cert
      interfaces = fact_on(host, 'interfaces').strip.split(',')
      interfaces.each do |interface|
        ipaddress = fact_on(host, "ipaddress_#{interface}")

        next if ipaddress.nil? || ipaddress.empty? || ipaddress.start_with?('127.')

        host_entry[fqdn] << ipaddress.strip

        unless host_entry[fqdn].empty?
          suts_network_info[fqdn] = host_entry[fqdn]
        end
      end
    end

    # Get all of the repeated SUT IP addresses:
    #   1. Create a hash of elements that have a key that is the value and
    #      elements that are the same value
    #   2. Grab all elements that have more than one value (therefore, were
    #      repeated)
    #   3. Pull out an Array of all of the common element keys for future
    #      comparison
    common_ip_addresses = suts_network_info
      .values.flatten
      .group_by{ |x| x }
      .select{|k,v| v.size > 1}
      .keys

    # generate PKI certs for each SUT
    Dir.mktmpdir do |dir|
      pki_hosts_file = File.join(dir, 'pki.hosts')

      File.open(pki_hosts_file, 'w') do |fh|
        suts_network_info.each do |fqdn, ipaddresses|
          fh.puts ([fqdn] + (ipaddresses - common_ip_addresses)) .join(',')
        end
      end

      copy_to(ca_sut, pki_hosts_file, host_dir)
      # generate certs
      on(ca_sut, "cd #{host_dir}; cat #{host_dir}/pki.hosts | xargs bash make.sh")
    end

    # if a local_dir was provided, copy everything down to it
    unless local_dir.empty?
      FileUtils.mkdir_p local_dir
      scp_from( ca_sut, host_dir, local_dir )
    end
  end


  # Copy a single SUT's PKI certs (with cacerts) onto an SUT.
  #
  # This simulates the result of pki::copy
  #
  # The directory structure is:
  #
  # SUT_BASE_DIR/
  #             pki/
  #                 cacerts/cacerts.pem
  #                 # This is a copy of cacerts.pem since cacerts.pem is a
  #                 # collection of the CA certificates in pupmod-simp-pki
  #                 cacerts/simp_auto_ca.pem
  #                 public/fdqn.pub
  #                 private/fdqn.pem
  def copy_pki_to(sut, local_pki_dir, sut_base_dir = '/etc/pki/simp-testing')
      fqdn                = fact_on(sut, 'fqdn')
      sut_pki_dir         = File.join( sut_base_dir, 'pki' )
      local_host_pki_tree = File.join(local_pki_dir,'pki','keydist',fqdn)
      local_cacert = File.join(local_pki_dir,'pki','demoCA','cacert.pem')

      sut.mkdir_p("#{sut_pki_dir}/public")
      sut.mkdir_p("#{sut_pki_dir}/private")
      sut.mkdir_p("#{sut_pki_dir}/cacerts")
      copy_to(sut, "#{local_host_pki_tree}/#{fqdn}.pem",   "#{sut_pki_dir}/private/")
      copy_to(sut, "#{local_host_pki_tree}/#{fqdn}.pub",   "#{sut_pki_dir}/public/")

      copy_to(sut, local_cacert, "#{sut_pki_dir}/cacerts/simp_auto_ca.pem")

      # NOTE: to match pki::copy, 'cacert.pem' is copied to 'cacerts.pem'
      copy_to(sut, local_cacert, "#{sut_pki_dir}/cacerts/cacerts.pem")

      # Need to hash all of the CA certificates so that apps can use them
      # properly! This must happen on the host itself since it needs to match
      # the native hashing algorithms.
      hash_cmd = <<-EOM.strip
cd #{sut_pki_dir}/cacerts; \
for x in *; do \
  if [ ! -h "$x" ]; then \
    `openssl x509 -in $x >/dev/null 2>&1`; \
    if [ $? -eq 0 ]; then \
      hash=`openssl x509 -in $x -hash | head -1`; \
      ln -sf $x $hash.0; \
    fi; \
   fi; \
done
      EOM

      on(sut, hash_cmd)
  end

  # Copy a CA keydist/ directory of CA+host certs into an SUT
  #
  # This simulates the output of FakeCA's gencerts_nopass.sh to keydist/
  def copy_keydist_to( ca_sut = master, host_keydist_dir = nil  )
    if !host_keydist_dir
      modulepath = puppet_modulepath_on(ca_sut)

      host_keydist_dir = "#{modulepath.first}/pki/files/keydist"
    end
    on ca_sut, "rm -rf #{host_keydist_dir}/*"
    ca_sut.mkdir_p(host_keydist_dir)
    on ca_sut, "cp -pR /root/pki/keydist/. #{host_keydist_dir}/"
    on ca_sut, "chgrp -R puppet #{host_keydist_dir}"
  end


  # Activate all network interfaces on the target system
  #
  # This is generally needed if the upstream vendor does not activate all
  # interfaces by default (EL7 for example)
  #
  # Can be passed any number of hosts either singly or as an Array
  def activate_interfaces(hosts)
    parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
    block_on(hosts, :run_in_parallel => parallel) do |host|
      interfaces_fact = retry_on(host,'facter interfaces', verbose: true).stdout

      interfaces = interfaces_fact.strip.split(',')
      interfaces.delete_if { |x| x =~ /^lo/ }

      interfaces.each do |iface|
        if fact_on(host, "ipaddress_#{iface}").strip.empty?
          on(host, "ifup #{iface}", :accept_all_exit_codes => true)
        end
      end
    end
  end


  ## Inline Hiera Helpers ##
  ## These will be integrated into core Beaker at some point ##

  # Set things up for the inline hieradata functions 'set_hieradata_on'
  # and 'clear_temp_hieradata'
  #
  #
  require 'rspec'
  RSpec.configure do |c|
    c.before(:all) do
      @temp_hieradata_dirs = @temp_hieradata_dirs || []
    end

    # We can't guarantee that the upstream vendor isn't disabling interfaces so
    # we need to turn them on at each context run
    c.before(:context) do
      activate_interfaces(hosts) unless ENV['BEAKER_no_fix_interfaces']
    end

    c.after(:all) do
      clear_temp_hieradata
    end
  end


  # Writes a YAML file in the Hiera :datadir of a Beaker::Host.
  #
  # @note This is useless unless Hiera is configured to use the data file.
  #   @see `#write_hiera_config_on`
  #
  # @param sut  [Array<Host>, String, Symbol] One or more hosts to act upon.
  #
  # @param hieradata [Hash, String] The full hiera data structure to write to
  #   the system.
  #
  # @param terminus [String]  DEPRECATED - This will be removed in a future
  #   release and currently has no effect.
  #
  # @return [Nil]
  #
  # @note This creates a tempdir on the host machine which should be removed
  #   using `#clear_temp_hieradata` in the `after(:all)` hook.  It may also be
  #   retained for debugging purposes.
  #
  def write_hieradata_to(sut, hieradata, terminus = 'deprecated')
    @temp_hieradata_dirs ||= []
    data_dir = Dir.mktmpdir('hieradata')
    @temp_hieradata_dirs << data_dir

    fh = File.open(File.join(data_dir, 'common.yaml'), 'w')
    if hieradata.is_a?(String)
      fh.puts(hieradata)
    else
      fh.puts(hieradata.to_yaml)
    end
    fh.close

    copy_hiera_data_to sut, File.join(data_dir, 'common.yaml')
  end

  # A shim to stand in for the now deprecated copy_hiera_data_to function
  #
  # @param sut [Host]  One host to act upon
  #
  # @param [Path] File containing hiera data
  def copy_hiera_data_to(sut, path)
    copy_to(sut, path, hiera_datadir(sut))
  end

  # A shim to stand in for the now deprecated hiera_datadir function
  #
  # Note: This may not work if you've shoved data somewhere that is not the
  # default and/or are manipulating the default hiera.yaml.
  #
  # @param sut  [Host] One host to act upon
  #
  # @returns [String] Path to the Hieradata directory on the target system
  def hiera_datadir(sut)
    # This output lets us know where Hiera is configured to look on the system
    puppet_lookup_info = on(sut, 'puppet lookup --explain test__simp__test').output.strip.lines

    if sut.puppet['manifest'].nil? || sut.puppet['manifest'].empty?
      fail("No output returned from `puppet config print manifest` on #{sut}")
    end

    puppet_env_path = File.dirname(sut.puppet['manifest'])

    # We'll just take the first match since Hiera will find things there
    puppet_lookup_info = puppet_lookup_info.grep(/Path "/).grep(Regexp.new(puppet_env_path))

    # Grep always returns an Array
    if puppet_lookup_info.empty?
      fail("Could not determine hiera data directory under #{puppet_env_path} on #{sut}")
    end

    # Snag the actual path without the extra bits
    puppet_lookup_info = puppet_lookup_info.first.strip.split('"').last

    # Make the parent directories exist
    sut.mkdir_p(File.dirname(puppet_lookup_info))

    # We just want the data directory name
    datadir_name = puppet_lookup_info.split(puppet_env_path).last

    # Grab the file separator to add back later
    file_sep = datadir_name[0]

    # Snag the first entry (this is the data directory)
    datadir_name = datadir_name.split(file_sep)[1]

    # Constitute the full path to the data directory
    datadir_path = puppet_env_path + file_sep + datadir_name

    # Return the path to the data directory
    return datadir_path
  end

  # Write the provided data structure to Hiera's :datadir and configure Hiera to
  # use that data exclusively.
  #
  # @note This is authoritative.  It manages both Hiera data and configuration,
  #   so it may not be used with other Hiera data sources.
  #
  # @param sut  [Array<Host>, String, Symbol] One or more hosts to act upon.
  #
  # @param heradata [Hash, String] The full hiera data structure to write to
  #   the system.
  #
  # @param terminus [String] DEPRECATED - Will be removed in a future release.
  #        All hieradata is written to the first discovered path via 'puppet
  #        lookup'
  #
  # @return [Nil]
  #
  def set_hieradata_on(sut, hieradata, terminus = 'deprecated')
    write_hieradata_to sut, hieradata
  end


  # Clean up all temporary hiera data files.
  #
  # Meant to be called from after(:all)
  def clear_temp_hieradata
    if @temp_hieradata_dirs && !@temp_hieradata_dirs.empty?
      @temp_hieradata_dirs.each do |data_dir|
        if File.exists?(data_dir)
          FileUtils.rm_r(data_dir)
        end
      end
    end
  end


  # pluginsync custom facts for all modules
  def pluginsync_on( suts = hosts )
    puts "== pluginsync_on'" if ENV['BEAKER_helpers_verbose']
    pluginsync_manifest =<<-PLUGINSYNC_MANIFEST
    file { $::settings::libdir:
          ensure  => directory,
          source  => 'puppet:///plugins',
          recurse => true,
          purge   => true,
          backup  => false,
          noop    => false
        }
    PLUGINSYNC_MANIFEST
    parallel = (ENV['BEAKER_SIMP_parallel'] == 'yes')
    apply_manifest_on(hosts, pluginsync_manifest, :run_in_parallel => parallel)
  end


  # Looks up latest `puppet-agent` version by the version of its `puppet` gem
  #
  # @param puppet_version [String] target Puppet gem version.  Works with
  #   Gemfile comparison syntax (e.g., '4.0', '= 4.2', '~> 4.3.1', '> 5.1, < 5.5')
  #
  # @return [String,Nil] the `puppet-agent` version or nil
  #
  def latest_puppet_agent_version_for( puppet_version )
    return nil if puppet_version.nil?

    require 'rubygems/requirement'
    require 'rubygems/version'
    require 'yaml'

    _puppet_version = puppet_version.strip.split(',')


    @agent_version_table ||= YAML.load_file(
                               File.expand_path(
                                 '../../files/puppet-agent-versions.yaml',
                                 File.dirname(__FILE__)
                             )).fetch('version_mappings')
    _pair = @agent_version_table.find do |k,v|
      Gem::Requirement.new(_puppet_version).satisfied_by?(Gem::Version.new(k))
    end
    result = _pair ? _pair.last : nil

    # If we didn't get a match, go look for published rubygems
    unless result
      puppet_gems = nil

      Bundler.with_clean_env do
        puppet_gems = %x(gem search -ra -e puppet).match(/\((.+)\)/)
      end

      if puppet_gems
        puppet_gems = puppet_gems[1].split(/,?\s+/).select{|x| x =~ /^\d/}

        # If we don't have a full version string, we need to massage it for the
        # match.
        begin
          if _puppet_version.size == 1
            Gem::Version.new(_puppet_version[0])
            if _puppet_version[0].count('.') < 2
             _puppet_version = "~> #{_puppet_version[0]}"
            end
          end
        rescue ArgumentError
          # this means _puppet_version is not just a version, but a version
          # specifier such as "= 5.2.3", "<= 5.1", "> 4", "~> 4.10.7"
        end

        result = puppet_gems.find do |ver|
          Gem::Requirement.new(_puppet_version).satisfied_by?(Gem::Version.new(ver))
        end
      end
    end

    return result
  end

  # returns hash with :puppet_install_version, :beaker_puppet_collection,
  # and :puppet_install_type keys determined from environment variables,
  # host settings, and/or defaults
  #
  # NOTE: BEAKER_PUPPET_AGENT_VERSION or PUPPET_INSTALL_VERSION or
  #       PUPPET_VERSION takes precedence over BEAKER_PUPPET_COLLECTION
  #       or host.options['puppet_collection'], when both a puppet
  #       install version and a puppet collection are specified. This is
  #       because the puppet install version can specify more precise
  #       version information than is available from a puppet collection.
  def get_puppet_install_info
    # The first match is internal Beaker and the second is legacy SIMP
    puppet_install_version = ENV['BEAKER_PUPPET_AGENT_VERSION'] || ENV['PUPPET_INSTALL_VERSION'] || ENV['PUPPET_VERSION']

    if puppet_install_version and !puppet_install_version.strip.empty?
      puppet_agent_version = latest_puppet_agent_version_for(puppet_install_version.strip)
    end

    if puppet_agent_version.nil?
      if puppet_collection = (ENV['BEAKER_PUPPET_COLLECTION'] || host.options['puppet_collection'])
        if puppet_collection =~ /puppet(\d+)/
          puppet_install_version = "~> #{$1}"
          puppet_agent_version = latest_puppet_agent_version_for(puppet_install_version)
        else
          raise("Error: Puppet Collection '#{puppet_collection}' must match /puppet(\\d+)/")
        end
      else
        puppet_agent_version = DEFAULT_PUPPET_AGENT_VERSION
      end
    end

    if puppet_collection.nil?
      base_version = puppet_agent_version.to_i
      puppet_collection = "puppet#{base_version}" if base_version >= 5
    end

    { :puppet_install_version   => puppet_agent_version,
      :beaker_puppet_collection => puppet_collection,
      :puppet_install_type      => ENV.fetch('PUPPET_INSTALL_TYPE', 'agent')
    }
  end


  # Replacement for `install_puppet` in spec_helper_acceptance.rb
  def install_puppet
    install_info = get_puppet_install_info

    # In case  Beaker needs this info internally
    ENV['PUPPET_INSTALL_VERSION'] = install_info[:puppet_install_version]
    unless install_info[:puppet_collection].nil?
      ENV['BEAKER_PUPPET_COLLECTION'] = install_info[:puppet_collection]
    end

    require 'beaker/puppet_install_helper'

    run_puppet_install_helper(install_info[:puppet_install_type], install_info[:puppet_install_version])
  end
end
