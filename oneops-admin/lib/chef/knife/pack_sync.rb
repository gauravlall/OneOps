require 'cms'
require 'chef/knife/core/object_loader'
require 'fog'
require 'kramdown'

class Chef
  class Knife
    class UI
      def debug(message)
        stdout.puts message if @config[:verbosity] >= 2
      end
    end

    VISIBILITY_ALT_NS_TAG = 'enableForOrg'

    class PackSync < Chef::Knife
      banner "knife pack sync PACK (options)"

      option :all,
             :short       => "-a",
             :long        => "--all",
             :description => "Sync all packs"

      option :register,
             :short       => "-r REGISTER",
             :long        => "--register REGISTER",
             :description => "Specify the source register name to use during sync"

      option :version,
             :short       => "-v VERSION",
             :long        => "--version VERSION",
             :description => "Specify the source register version to use during sync"

      option :cookbook_path,
             :short       => "-o PATH:PATH",
             :long        => "--cookbook-path PATH:PATH",
             :description => "A colon-separated path to look for cookbooks in",
             :proc        => lambda {|o| o.split(":")}

      option :reload,
             :long        => "--reload",
             :description => "Remove the current pack before uploading"

      option :semver,
             :long        => "--semver",
             :description => "Creates new patch version for each change"


      option :msg,
             :short       => '-m MSG',
             :long        => '--msg MSG',
             :description => "Append a message to the comments"

      def packs_loader
        @packs_loader ||= Knife::Core::ObjectLoader.new(Chef::Pack, ui)
      end

      # safety measure: make sure no packs conflict in scope
      def validate_packs
        config[:pack_path] ||= Chef::Config[:pack_path]
        config[:version]   ||= Chef::Config[:version]

        # keyed by group-name-version
        pack_map = {}

        config[:pack_path].each do |dir|

          pack_file_pattern = "#{dir}/*.rb"
          files             = Dir.glob(pack_file_pattern)
          files.each do |file|
            pack = packs_loader.load_from("packs", file)
            key  = "#{get_group}**#{pack.name.downcase}**#{pack.version.presence || config[:version].split('.').first}"
            if pack_map.has_key?(key)
              puts "error: conflict of pack group-name-version: #{key} #{file} to #{pack_map[key]}"
              puts "no packs loaded."
              exit 1
            else
              pack_map[key] = "#{file}"
            end
          end
        end
      end

      def run
        config[:pack_path] ||= Chef::Config[:pack_path]
        config[:register]  ||= Chef::Config[:register]
        config[:version]   ||= Chef::Config[:version]
        config[:semver]    ||= ENV['SEMVER'].present?

        comments = "#{ENV['USER']}:#{$0}"
        comments += " #{config[:msg]}" if config[:msg]

        validate_packs

        unless Cms::Namespace.first(:params => {:nsPath => "#{Chef::Config[:nspath]}/#{get_group}/packs"})
          ui.error("Can't find namespace #{nspath}. Please register your source first with the register command.")
          exit 1
        end

        if config[:all]
          config[:pack_path].each do |dir|
            pack_file_pattern = "#{dir}/*.rb"
            files             = Dir.glob(pack_file_pattern)
            files.each do |file|
              unless upload_template_from_file(file, comments)
                ui.error('exiting')
                exit 1
              end
            end
          end
        elsif @name_args.present?
          @name_args.each do |pack|
            file = [pack, 'rb'].join('.')
            unless upload_template_from_file(file, comments)
              ui.error('exiting')
              exit 1
            end
          end
        else
          ui.error 'You must specify the pack name or use the --all option.'
          exit 1
        end
      end

      def get_remote_dir
        unless @remote_dir
          conn       = get_connection
          env_bucket = Chef::Config[:environment_name]

          @remote_dir = conn.directories.get(env_bucket)
          if @remote_dir.nil?
            @remote_dir = conn.directories.create(:key => env_bucket)
            ui.debug "created #{env_bucket}"
          end
        end
        @remote_dir
      end

      def get_connection
        return @object_store_connection if @object_store_connection
        object_store_provider = Chef::Config[:object_store_provider]

        case object_store_provider
          when 'OpenStack'
            @object_store_connection = Fog::Storage.new({
                                                          :provider           => object_store_provider,
                                                          :openstack_username => Chef::Config[:object_store_user],
                                                          :openstack_api_key  => Chef::Config[:object_store_pass],
                                                          :openstack_auth_url => Chef::Config[:object_store_endpoint]
                                                        })
          when 'Local'
            @object_store_connection = Fog::Storage.new({
                                                          :provider   => object_store_provider,
                                                          :local_root => Chef::Config[:object_store_local_root]
                                                        })
          else
            raise Exception.new("unsupported object_store_provider: #{object_store_provider}")
        end

        return @object_store_connection
      end

      def gen_doc(ns, pack)
        if Chef::Config[:object_store_provider].blank?
          ui.info "skipping doc - no object_store_provider is set"
          return
        end

        remote_dir  = get_remote_dir
        initial_dir = Dir.pwd
        doc_dir     = initial_dir + '/packs/doc'

        if File.directory? doc_dir
          Dir.chdir doc_dir
          ["#{pack.name}.md", "#{pack.name}.png"].each do |file|
            remote_file = ns + '/' + file
            local_file  = doc_dir + '/' + file
            unless File.exists?(local_file)
              ui.warn "missing local file: #{local_file}"
              next
            end
            if file =~ /\.md$/
              content = Kramdown::Document.new(File.read(local_file)).to_html
              remote_file.gsub!(".md", ".html")
              File.write(local_file.gsub(".md", ".html"), content)
            else
              content = File.open(local_file)
            end
            # remove first slash in ns path
            remote_file = remote_file[1..-1]
            ui.info "doc: #{local_file}   =>   remote: #{remote_file}"
            obj = {:key => remote_file, :body => content}
            if remote_file =~ /\.html/
              obj['content_type'] = 'text/html'
            end

            remote_dir.files.create obj
          end
        end
        Dir.chdir initial_dir
      end

      def get_group
        Chef::Config[:register]
      end

      def upload_template_from_file(file, comments)
        pack = packs_loader.load_from(Chef::Config[:pack_path], file)
        pack.name.downcase!
        if config[:semver] || pack.semver?
          return upload_template_from_file_ver_update(pack, comments)
        else
          return upload_template_from_file_no_verupdate(pack, comments)
        end
      end

      def upload_template_from_file_ver_update(pack, comments)
        if pack.ignore
          ui.info("Ignoring pack #{pack.name} version #{pack.version}")
          return true
        end

        if config[:reload]
          ui.warn('Reload option is no longer available in semver mode, all pack versions are immutable. If you need to force new patch version, force a change to the content of pack file (i.e. pack description) and do a pack sync.')
        end

        signature = check_pack_version_ver_update(pack)

        ui.info("============> #{pack.name} #{pack.version}")
        ns = "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}"

        # If pack signature matches nothing to do.
        unless signature
          # Documentation could have been updated, reload it just in case.
          gen_doc(ns, pack)
          return true
        end

        Log.debug(pack.to_yaml) if Log.debug?

        version_ci = setup_pack_version(pack, comments, signature)
        return false unless version_ci

        begin
          gen_doc(ns, pack)

          # Upload design template
          upload_template(ns, pack.name, 'mgmt.catalog', pack, '_default', pack.design_resources, comments)

          # Upload manifest templates
          pack.environments.each do |name, _|
            setup_mode(pack, name, comments)
            upload_template("#{ns}/#{name}", pack.name, 'mgmt.manifest', pack, name, pack.environment_resources(name), comments)
          end
        rescue Exception => e
          ui.error(e.message)
          ui.info('Attempting to clean up...')
          begin
            version_ci.destroy
          rescue Exception
            ui.warn("Failed to clean up pack #{pack.name} version #{pack.version}!")
          end
          raise e
        end

        ui.info("Uploaded pack #{pack.name} version #{pack.version}")
        ui.info("Uploaded pack #{pack.name} version #{pack.version} [signature: #{signature}]")
        return true
      end

      def upload_template_from_file_no_verupdate(pack, comments)
        signature = Digest::MD5.hexdigest(pack.signature)

        pack.version((pack.version.presence || config[:version]).split('.').first) # default to the global knife version if not specified

        if pack.ignore
          ui.info("Ignoring pack #{pack.name} version #{pack.version}")
          return true
        end

        ui.info("============> #{pack.name} #{pack.version}")

        # If pack signature matches but reload option is not set - bail
        return true if !config[:reload] && check_pack_version_no_ver_update(pack, signature)

        Log.debug(pack.to_yaml) if Log.debug?

        # First, check to see if anything from CMS need to
        # flip to pending_deletion
        fix_delta_cms(pack)

        # setup pack version namespace first
        pack_version = setup_pack_version(pack, comments, '')
        return false unless pack_version

        ns = "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}"
        gen_doc(ns, pack)

        # Upload design template
        upload_template(ns, pack.name, 'mgmt.catalog', pack, '_default', pack.design_resources, comments)

        # Upload manifest templates
        pack.environments.each do |name, _|
          setup_mode(pack, name, comments)
          upload_template("#{ns}/#{name}", pack.name, 'mgmt.manifest', pack, name, pack.environment_resources(name), comments)
        end

        pack_version.ciAttributes.commit = signature
        unless save(pack_version)
          ui.warn("Failed to update signature for pack #{pack.name} version #{pack.version}")
        end
        ui.info("Uploaded pack #{pack.name} version #{pack.version} [signature: #{signature}]")
        return true
      end


      private

      def fix_delta_cms(pack)
        nsPath  = "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}"
        cmsEnvs = ['_default'] + Cms::Ci.all(:params => {:nsPath => nsPath, :ciClassName => 'mgmt.Mode'}).map(&:ciName)
        cmsEnvs.each do |env|
          relations = fix_rels_from_cms(pack, env)
          fix_ci_from_cms(pack, env, relations, cmsEnvs)
        end
      end

      def fix_rels_from_cms(pack, env = '_default')
        pack_rels   = pack.relations
        target_rels = []
        scope       = (env == '_default') ? '' : "/#{env}"
        Cms::Relation.all(:params => {:nsPath        => "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}#{scope}",
                                      :includeToCi   => true,
                                      :includeFromCi => true}).each do |r|
          new_state      = nil
          fromCiName     = r.fromCi.ciName
          toCiName       = r.toCi.ciName
          relationShort  = r.relationName.split('.').last
          key            = "#{fromCiName}::#{relationShort.scan(/[A-Z][a-z]+/).join('_').downcase}::#{toCiName}"
          exists_in_pack = pack_rels.include?(key)
          # Search through resource to determine if relation exists or not
          unless exists_in_pack
            case relationShort
              when 'Payload'
                exists_in_pack = pack.resources[fromCiName] && pack.resources[fromCiName].include?('payloads') &&
                  pack.resources[fromCiName]['payloads'].include?(toCiName)
              when 'WatchedBy'
                exists_in_pack = pack.resources[fromCiName] && pack.resources[fromCiName].include?('monitors') &&
                  pack.resources[fromCiName]['monitors'].include?(toCiName)
              when 'Requires'
                exists_in_pack = pack.resources[fromCiName] && pack.resources[toCiName]
              when 'Entrypoint'
                exists_in_pack = pack.entrypoints.include?(toCiName)
            end
          end

          target_rels.push(toCiName) if exists_in_pack && !target_rels.include?(toCiName)

          if exists_in_pack && r.relationState == 'pending_deletion'
            new_state = 'default'
          elsif !exists_in_pack && r.relationState != 'pending_deletion'
            new_state = 'pending_deletion'
          end

          if new_state
            r.relationState = new_state
            if save(r)
              ui.debug("Successfuly updated ciRelationState to #{new_state} #{r.relationName} #{r.fromCi.ciName} <-> #{r.toCi.ciName} for #{env}")
            else
              ui.error("Failed to update ciRelationState to #{new_state} #{r.relationName} #{r.fromCi.ciName} <-> #{r.toCi.ciName} for #{env}")
            end
          end
        end
        target_rels
      end

      def fix_ci_from_cms(pack, env, relations, environments)
        scope          = (env == '_default') ? '' : "/#{env}"
        pack_resources = pack.resources
        Cms::Ci.all(:params => {:nsPath => "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}#{scope}"}).each do |resource|
          new_state      = nil
          exists_in_pack = pack_resources.include?(resource.ciName) || relations.include?(resource.ciName) || environments.include?(resource.ciName)
          if exists_in_pack && resource.ciState == 'pending_deletion'
            new_state = 'default'
          elsif !exists_in_pack && resource.ciState != 'pending_deletion'
            new_state = 'pending_deletion'
          end
          if new_state
            resource.ciState = new_state
            if save(resource)
              ui.debug("Successfuly updated ciState to #{new_state} for #{resource.ciName} for #{env}")
            else
              ui.error("Failed to update ciState to #{new_state} for #{resource.ciName} for #{env}")
            end
          end
        end
      end

      def check_pack_version_ver_update(pack)
        all_versions = Cms::Ci.all(:params => {:nsPath       => "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}",
                                               :ciClassName  => 'mgmt.Version',
                                               :includeAltNs => VISIBILITY_ALT_NS_TAG})
        major, minor, patch = (pack.version.blank? ? config[:version] : pack.version).split('.')
        minor               = '0' if minor.blank?

        # Need to filter version for the same major and find latest patch version for the same minor.
        latest_patch        = nil
        latest_patch_number = -1
        versions            = all_versions.select do |ci_v|
          split = ci_v.ciName.split('.')
          if major == split[0] && minor == split[1] && split[2].to_i > latest_patch_number
            latest_patch        = ci_v
            latest_patch_number = split[2].to_i
          end
          major == split[0]
        end

        if versions.size > 0
          version_ci = latest_patch || versions.sort_by(&:ciName).last
          # Carry over 'enable' and 'visibility' from the latest patch or latest version overall.
          pack.enabled(version_ci.ciAttributes.attributes['enabled'] != 'false')
          pack.visibility(version_ci.altNs.attributes[VISIBILITY_ALT_NS_TAG])
        end

        if patch.present?
          # Check to make sure version does not already exist.
          version = "#{major}.#{minor}.#{patch}"
          if versions.find {|ci_v| ci_v.ciName == version}
            ui.warn("Pack #{pack.name} version #{pack.version} explicitly specified but it already exists, ignore it - will SKIP pack loading, but will try to update docs.")
            return nil
          else
            pack.version(version)
            ui.info("Pack #{pack.name} version #{pack.version} explicitly specified and it does not exist yet, will load.")
            return pack.signature
          end
        else
          ui.info("Pack #{pack.name} version #{pack.version} - patch version is not explicitly specified, continue with checking for latest patch version for it.")
        end

        if latest_patch
          pack.version(latest_patch.ciName)
          signature = Digest::MD5.hexdigest(pack.signature)
          if latest_patch.ciAttributes.attributes['commit'] == signature
            ui.info("Pack #{pack.name} latest patch version #{latest_patch.ciName} matches signature (#{signature}), will skip pack loading, but will try to update docs.")
            return nil
          else
            ui.info("Pack #{pack.name} latest patch version #{latest_patch.ciName} signature is different from new pack signature #{signature}, will increment patch version and load.")
            pack.version("#{major}.#{minor}.#{latest_patch.ciName.split('.')[2].to_i + 1}")
            return pack.signature
          end
        else
          ui.info("No patches found for #{pack.name} version #{major}.#{minor}, start at patch 0 and load.")
          pack.version("#{major}.#{minor}.0")
          return pack.signature
        end
      end

      def check_pack_version_no_ver_update(pack, signature)
        source       = "#{Chef::Config[:nspath]}/#{get_group}/packs"
        pack_version = Cms::Ci.first(:params => {:nsPath => "#{source}/#{pack.name}", :ciClassName => 'mgmt.Version', :ciName => pack.version})
        if pack_version.nil?
          ui.info("Pack #{pack.name} version #{pack.version} not found")
          return false
        else
          if pack_version.ciAttributes.attributes.key?('commit') && pack_version.ciAttributes.commit == signature
            ui.info("Pack #{pack.name} version #{pack.version} matches signature #{signature}, use --reload to force load.")
            return true
          else
            ui.warn("Pack #{pack.name} version #{pack.version} signature is different from file signature #{signature}")
            return false
          end
        end
      end

      def setup_pack_version(pack, comments, signature)
        source  = "#{Chef::Config[:nspath]}/#{get_group}/packs"
        pack_ci = Cms::Ci.first(:params => {:nsPath => "#{source}", :ciClassName => 'mgmt.Pack', :ciName => pack.name})
        if pack_ci
          ui.debug("Updating pack #{pack.name}")
        else
          ui.info("Creating pack CI #{pack.name}")
          pack_ci = build('Cms::Ci',
                          :nsPath      => "#{source}",
                          :ciClassName => 'mgmt.Pack',
                          :ciName      => pack.name)
        end

        pack_ci.comments                 = comments
        pack_ci.ciAttributes.pack_type   = pack.type
        pack_ci.ciAttributes.description = pack.description
        pack_ci.ciAttributes.category    = pack.category
        pack_ci.ciAttributes.owner       = pack.owner

        if save(pack_ci)
          ui.debug("Successfuly saved pack CI #{pack.name}")
          pack_version = Cms::Ci.first(:params => {:nsPath      => "#{source}/#{pack.name}",
                                                   :ciClassName => 'mgmt.Version',
                                                   :ciName      => pack.version})
          if pack_version
            ui.debug("Updating pack CI #{pack.name} version #{pack.version}")
          else
            ui.info("Creating pack CI #{pack.name} version #{pack.version}")
            pack_version = build('Cms::Ci',
                                 :nsPath       => "#{source}/#{pack.name}",
                                 :ciClassName  => 'mgmt.Version',
                                 :ciName       => pack.version,
                                 :ciAttributes => {:enabled => pack.enabled},
                                 :altNs        => {VISIBILITY_ALT_NS_TAG => pack.visibility})
          end

          pack_version.comments                 = comments
          pack_version.ciAttributes.description = pack.description
          pack_version.ciAttributes.commit      = signature

          if save(pack_version)
            ui.debug("Successfuly saved pack version CI for: #{pack.name} #{pack.version}")
            return pack_version
          else
            ui.error("Could not save pack version CI for: #{pack.name} #{pack.version}")
          end
        else
          ui.error("Could not save pack CI #{pack.name}")
        end
        ui.error("Unable to setup namespace for pack #{pack.name} version #{pack.version}")

        return false
      end

      def setup_mode(pack, env, comments)
        nspath = "#{Chef::Config[:nspath]}/#{get_group}/packs/#{pack.name}/#{pack.version}"
        mode   = Cms::Ci.first(:params => {:nsPath => nspath, :ciClassName => 'mgmt.Mode', :ciName => env})
        if mode
          ui.debug("Updating pack #{pack.name} version #{pack.version} environment mode #{env}")
        else
          ui.info("Creating pack #{pack.name} version #{pack.version} environment mode #{env}")
          mode = build('Cms::Ci',
                       :nsPath      => nspath,
                       :ciClassName => 'mgmt.Mode',
                       :ciName      => env)
        end

        mode.comments                 = comments
        mode.ciAttributes.description = pack.description

        if save(mode)
          ui.debug("Successfuly saved pack mode CI #{env}")
          return mode
        else
          message = "Unable to setup namespace for pack #{pack.name} version #{pack.version} environment mode #{env}"
          ui.error(message)
          raise Exception.new(message)
        end
      end

      def upload_template(nspath, template_name, package, pack, env, resources, comments)
        ui.info("======> #{env}")
        Log.debug([pack.name, pack.version, package, nspath, resources, comments].to_yaml) if Log.debug?
        platform = upload_template_platform(nspath, template_name, package, pack, comments)
        if platform
          components = upload_template_components(nspath, platform, template_name, package, resources, comments)
          upload_template_depends_on(nspath, pack, resources, components, env)
          upload_template_managed_via(nspath, pack, resources, components)
          upload_template_entrypoint(nspath, pack, resources, components, platform, env)
          upload_template_monitors(nspath, resources, components, package)
          upload_template_payloads(nspath, resources, components)
          upload_template_procedures(nspath, pack, platform, env)
          upload_template_variables(nspath, pack, package, platform, env)
          upload_template_policies(nspath, pack, package, env)
        end
      end

      def upload_template_platform(nspath, template_name, package, pack, comments)
        ci_class_name = "#{package}.#{pack.type.capitalize}"
        platform      = Cms::Ci.first(:params => {:nsPath      => nspath,
                                                  :ciClassName => ci_class_name,
                                                  :ciName      => template_name})
        if platform
          ui.debug("Updating #{ci_class_name} for template #{template_name}")
        else
          ui.info("Creating #{ci_class_name} for template #{template_name}")
          platform = build('Cms::Ci',
                           :nsPath      => nspath,
                           :ciClassName => ci_class_name,
                           :ciName      => template_name)
        end

        plat_attrs = pack.platform && pack.platform[:attributes]
        if plat_attrs
          attrs = platform.ciAttributes.attributes
          attrs.each {|name, _| attrs[name] = plat_attrs[name] if plat_attrs.has_key?(name)}
        end

        platform.comments                 = comments
        platform.ciAttributes.description = pack.description
        platform.ciAttributes.source      = get_group
        platform.ciAttributes.pack        = pack.name.capitalize
        platform.ciAttributes.version     = pack.version

        if save(platform)
          ui.debug("Successfuly saved #{ci_class_name} for template #{template_name}")
          return platform
        else
          ui.error("Could not save #{ci_class_name}, skipping template #{template_name}")
          return false
        end
      end

      def upload_template_components(nspath, platform, template_name, package, resources, comments)
        components = {}
        relations  = Cms::Relation.all(:params => {:ciId              => platform.ciId,
                                                   :direction         => 'from',
                                                   :relationShortName => 'Requires',
                                                   :includeToCi       => true})

        resources.each do |resource_name, resource|
          class_name_parts     = resource[:cookbook].split('.')
          class_name_parts[-1] = class_name_parts[-1].capitalize
          class_name_parts     = class_name_parts.unshift(resource[:source]) if resource[:source]
          class_name_parts     = class_name_parts.unshift(package)
          ci_class_name        = class_name_parts.join('.')

          relation = relations.find {|r| r.toCi.ciName == resource_name && r.toCi.ciClassName == ci_class_name}

          if relation
            ui.debug("Updating resource #{resource_name} for template #{template_name}")
          else
            ui.info("Creating resource #{resource_name} for #{template_name}")
            relation = build('Cms::Relation',
                             :relationName => 'mgmt.Requires',
                             :nsPath       => nspath,
                             :fromCiId     => platform.ciId,
                             :toCiId       => 0,
                             :toCi         => build('Cms::Ci',
                                                    :nsPath      => nspath,
                                                    :ciClassName => ci_class_name,
                                                    :ciName      => resource_name))
          end

          relation.comments                    = comments
          relation.toCi.comments               = comments
          relation.relationAttributes.template = resource_name # default value for template attribute is the resource name
          requires_attrs                       = resource[:requires]
          if requires_attrs
            attrs = relation.relationAttributes.attributes
            attrs.each {|name, _| attrs[name] = requires_attrs[name] if requires_attrs[name]}
          end

          component_attrs = resource[:attributes]
          if component_attrs
            attrs = relation.toCi.ciAttributes.attributes
            attrs.each {|name, _| attrs[name] = component_attrs[name] if component_attrs.has_key?(name)}
          end

          if save(relation)
            ui.debug("Successfuly saved resource #{resource_name} for template #{template_name}")
            components[resource_name] = relation.toCiId
          else
            ui.error("Could not save resource #{resource_name}, skipping it")
          end
        end

        return components
      end

      def upload_template_depends_on(nspath, pack, resources, components, env)
        relation_name = "mgmt.#{env == '_default' ? 'catalog' : 'manifest'}.DependsOn"
        relations     = Cms::Relation.all(:params => {:nsPath       => nspath,
                                                      :relationName => relation_name})
        resources.each do |resource_name, _|
          next unless pack.depends_on[resource_name]
          pack.depends_on[resource_name].each do |do_class, __|
            next unless components[do_class] # skip if the target depends_on is not in this mode/env
            depends_on = relations.find {|d| d.fromCiId == components[resource_name] && d.toCiId == components[do_class]}
            if depends_on
              ui.debug("Updating depends on between #{resource_name} and #{do_class}")
            else
              ui.info("Creating depends on between #{resource_name} and #{do_class}")
              depends_on = build('Cms::Relation',
                                 :relationName => relation_name,
                                 :nsPath       => nspath,
                                 :fromCiId     => components[resource_name],
                                 :toCiId       => components[do_class])
            end

            attrs = pack.depends_on[resource_name][do_class]
            depends_on.relationAttributes.attributes.each do |name, ___|
              depends_on.relationAttributes.send(name+'=', attrs[name]) if attrs[name]
            end

            if save(depends_on)
              ui.debug("Successfuly saved depends on between #{resource_name} and #{do_class}")
            else
              ui.error("Could not save depends on between #{resource_name} and #{do_class} in #{nspath}, skipping it")
            end
          end
        end
      end

      def upload_template_managed_via(nspath, pack, resources, components)
        relation_name = 'mgmt.manifest.ManagedVia'
        relations     = Cms::Relation.all(:params => {:nsPath       => nspath,
                                                      :relationName => relation_name})
        resources.each do |resource_name, _|
          next unless pack.managed_via[resource_name]
          pack.managed_via[resource_name].each do |mv_class, __|
            managed_via = relations.find {|r| r.fromCiId == components[resource_name] && r.toCiId == components[mv_class]}
            if managed_via
              ui.debug("Updating managed via between #{resource_name} and #{mv_class}")
            else
              ui.info("Creating managed via between #{resource_name} and #{mv_class}")
              managed_via = build('Cms::Relation',
                                  :relationName => relation_name,
                                  :nsPath       => nspath,
                                  :fromCiId     => components[resource_name],
                                  :toCiId       => components[mv_class])
            end

            attrs = pack.managed_via[resource_name][mv_class]
            managed_via.relationAttributes.attributes.each do |name, ___|
              managed_via.relationAttributes.send(name+'=', attrs[name]) if attrs[name]
            end

            if save(managed_via)
              ui.debug("Successfuly saved managed via between #{resource_name} and #{mv_class}")
            else
              ui.error("Could not save managed via between #{resource_name} and #{mv_class}, skipping it")
            end
          end
        end
      end

      def upload_template_entrypoint(nspath, pack, resources, components, platform, env)
        relation_name = 'mgmt.Entrypoint'
        relations     = Cms::Relation.all(:params => {:ciId         => platform.ciId,
                                                      :nsPath       => nspath,
                                                      :direction    => 'from',
                                                      :relationName => relation_name})
        resources.each do |resource_name, _|
          next unless pack.environment_entrypoints(env)[resource_name]
          entrypoint = relations.find {|r| r.toCi.ciId == components[resource_name]}
          if entrypoint
            ui.debug("Updating entrypoint between platform and #{resource_name}")
          else
            ui.info("Creating entrypoint between platform and #{resource_name}")
            entrypoint = build('Cms::Relation',
                               :relationName => relation_name,
                               :nsPath       => nspath,
                               :fromCiId     => platform.ciId,
                               :toCiId       => components[resource_name])
          end

          entrypoint_attrs = pack.entrypoints[resource_name]['attributes']
          attrs            = entrypoint.relationAttributes.attributes
          attrs.each {|name, __| attrs[name] = entrypoint_attrs[name] if entrypoint_attrs[name]}

          if save(entrypoint)
            ui.debug("Successfuly saved entrypoint between platform and #{resource_name}")
          else
            ui.error("Could not save entrypoint between platform and #{resource_name}, skipping it")
          end
        end
      end

      def upload_template_monitors(nspath, resources, components, package)
        relation_name = "#{package}.WatchedBy"
        ci_class_name = "#{package}.Monitor"
        relations     = Cms::Relation.all(:params => {:nsPath       => nspath,
                                                      :relationName => relation_name,
                                                      :includeToCi  => true})

        resources.each do |resource_name, resource|
          next unless resource[:monitors]
          resource[:monitors].each do |monitor_name, monitor|
            relation = relations.find {|r| r.fromCiId == components[resource_name] && r.toCi.ciName == monitor_name}

            if relation
              ui.debug("Updating monitor #{monitor_name} for #{resource_name} in #{package}")
            else
              ui.info("Creating monitor #{monitor_name} for #{resource_name}")
              relation = build('Cms::Relation',
                               :relationName => relation_name,
                               :nsPath       => nspath,
                               :fromCiId     => components[resource_name])
              # For legacy reasons, we might have monitors with same name, so several components
              # link (via relation) to the same CI in the pack template. Therefore,
              # monitor CI may already exists.
              duplicate_ci_name_rel = relations.find {|r| r.toCi.ciName == monitor_name}
              if duplicate_ci_name_rel
                ui.warn("Monitor #{monitor_name} for component #{resource_name} is not uniquely named, will re-use existing payload CI with the same name")
                relation.toCiId = duplicate_ci_name_rel.toCiId
                if save(relation)
                  relation.add(relation)
                  relation.toCi = duplicate_ci_name_rel.toCi
                else
                  ui.error("Could not create WatchedBy relation #{monitor_name} for #{resource_name}, skipping it")
                  next
                end
              else
                relation.toCiId = 0
                relation.toCi = build('Cms::Ci',
                                      :nsPath      => nspath,
                                      :ciClassName => ci_class_name,
                                      :ciName      => monitor_name)
              end
            end

            attrs = relation.toCi.ciAttributes.attributes
            attrs.each do |name, _|
              if monitor[name]
                monitor[name] = monitor[name].to_json if monitor[name].is_a?(Hash)
                attrs[name]   = monitor[name]
              end
            end

            if save(relation)
              ui.debug("Successfuly saved monitor #{monitor_name} for #{resource_name} in #{package}")
            else
              ui.error("Could not save monitor #{monitor_name} for #{resource_name}, skipping it")
            end
          end
        end
      end

      def upload_template_payloads(nspath, resources, components)
        relation_name = 'mgmt.manifest.Payload'
        ci_class_name = 'mgmt.manifest.Qpath'
        relations     = Cms::Relation.all(:params => {:nsPath          => nspath,
                                                      :relationName    => relation_name,
                                                      :targetClassName => ci_class_name,
                                                      :includeToCi     => true})
        existing_rels = relations.inject({}) {|h, r| h[r.toCi.ciName.downcase] = r; h}

        resources.each do |resource_name, resource|
          next unless resource[:payloads]
          resource[:payloads].each do |payload_name, payload|
            relation = relations.find {|r| r.toCi.ciName == payload_name && r.fromCiId == components[resource_name]}

            # For legacy reasons, we might have payloads with same name, so several components
            # link (via relation) to the same pyaload CI in the pack template. Therefore,
            # payload CI may already exists.
            duplicate_ci_name_rel = existing_rels[payload_name.downcase]
            if duplicate_ci_name_rel && (!relation || relation.fromCiId != duplicate_ci_name_rel.fromCiId)
              ui.warn("Payload #{payload_name} for component #{resource_name} is not uniquely named, will re-use existing payload CI with the same name")
            end

            if relation
              ui.debug("Updating payload #{payload_name} for #{resource_name}")
            else
              ui.info("Creating payload #{payload_name} for #{resource_name}")
              relation = build('Cms::Relation',
                               :relationName => relation_name,
                               :nsPath       => nspath,
                               :fromCiId     => components[resource_name])
              if duplicate_ci_name_rel
                relation.toCiId = duplicate_ci_name_rel.toCiId
                unless save(relation)
                  ui.error("Could not create Qpath relation #{payload_name} for #{resource_name}, skipping it")
                  next
                end
                relation.toCi = duplicate_ci_name_rel.toCi
              else
                relation.toCiId = 0
                relation.toCi = build('Cms::Ci',
                                      :nsPath      => nspath,
                                      :ciClassName => ci_class_name,
                                      :ciName      => payload_name)
              end
            end

            attrs = relation.toCi.ciAttributes.attributes
            attrs.each {|name, _| attrs[name] = payload[name] if payload[name]}

            if save(relation)
              existing_rels[payload_name] = relation unless duplicate_ci_name_rel
              ui.debug("Successfuly saved payload #{payload_name} for #{resource_name}")
            else
              ui.error("Could not save payload #{payload_name} for #{resource_name}, skipping it")
            end
          end
        end
      end

      def upload_template_procedures(nspath, pack, platform, env)
        relation_name = 'mgmt.manifest.ControlledBy'
        ci_class_name = 'mgmt.manifest.Procedure'
        relations     = Cms::Relation.all(:params => {:ciId            => platform.ciId,
                                                      :nsPath          => nspath,
                                                      :direction       => 'from',
                                                      :relationName    => relation_name,
                                                      :targetClassName => ci_class_name,
                                                      :includeToCi     => true})
        pack.environment_procedures(env).each do |procedure_name, procedure_attributes|
          relation = relations.find {|r| r.toCi.ciName == procedure_name}
          if relation
            ui.debug("Updating procedure #{procedure_name} for environment #{env}")
          else
            ui.info("Creating procedure #{procedure_name} for environment #{env}")
            relation = build('Cms::Relation',
                             :relationName => relation_name,
                             :nsPath       => nspath,
                             :fromCiId     => platform.ciId,
                             :toCiId       => 0,
                             :toCi         => build('Cms::Ci',
                                                    :nsPath      => nspath,
                                                    :ciClassName => ci_class_name,
                                                    :ciName      => procedure_name))
          end

          attrs = relation.toCi.ciAttributes.attributes
          attrs.each do |name, _|
            if procedure_attributes[name]
              if name == 'arguments' && procedure_attributes[name].is_a?(Hash)
                procedure_attributes[name] = procedure_attributes[name].to_json
              end
              attrs[name] = procedure_attributes[name]
            end
          end

          if save(relation)
            ui.debug("Successfuly saved procedure #{procedure_name} for environment #{env}")
          else
            ui.error("Could not save procedure #{procedure_name} for environment #{env}, skipping it")
          end
        end
      end

      def upload_template_variables(nspath, pack, package, platform, env)
        relation_name = "#{package}.ValueFor"
        ci_class_name = "#{package}.Localvar"
        relations     = Cms::Relation.all(:params => {:ciId            => platform.ciId,
                                                      :direction       => 'to',
                                                      :relationName    => relation_name,
                                                      :targetClassName => ci_class_name,
                                                      :includeFromCi   => true})
        pack.environment_variables(env).each do |variable_name, var_attrs|
          relation = relations.find {|r| r.fromCi.ciName == variable_name}
          if relation
            ui.debug("Updating variable #{variable_name} for environment #{env}")
          else
            ui.info("Creating variable #{variable_name} for environment #{env}")
            relation = build('Cms::Relation',
                             :relationName => relation_name,
                             :nsPath       => nspath,
                             :toCiId       => platform.ciId,
                             :fromCiId     => 0,
                             :fromCi       => build('Cms::Ci',
                                                    :nsPath      => nspath,
                                                    :ciClassName => ci_class_name,
                                                    :ciName      => variable_name))
          end

          attrs = relation.fromCi.ciAttributes.attributes
          attrs.each {|name, _| attrs[name] = var_attrs[name] if var_attrs[name]}

          if save(relation)
            ui.debug("Successfuly saved variable #{variable_name} for environment #{env}")
          else
            ui.error("Could not save variable #{variable_name} for environment #{env}, skipping it")
          end
        end
      end

      def upload_template_policies(nspath, pack, package, env)
        ci_class_name = "#{package}.Policy"
        policies      = Cms::Ci.all(:params => {:nsPath      => nspath,
                                                :ciClassName => ci_class_name})
        pack.environment_policies(env).each do |policy_name, policy_attrs|
          policy = policies.find {|p| p.ciName == policy_name}
          unless policy
            policy = build('Cms::Ci',
                           :nsPath      => nspath,
                           :ciClassName => ci_class_name,
                           :ciName      => policy_name)
          end

          attrs = policy.ciAttributes.attributes
          attrs.each {|name, _| attrs[name] = policy_attrs[name] if policy_attrs[name]}

          if save(policy)
            ui.debug("Successfuly saved policy #{policy_name} attributes for environment #{env} and #{pack}")
          else
            ui.error("Could not save policy #{policy_name} attributes for environment #{env} and #{pack}, skipping it")
          end
        end
      end

      def save(object)
        Log.debug(object.to_yaml) if Log.debug?
        begin
          ok = object.save
          Log.warn(object.errors.full_messages.join('; ')) unless ok
        rescue Exception => e
          Log.info(object.to_yaml) unless Log.debug?
          Log.info(e.response.read_body)
        end
        ok ? object : false
      end

      def destroy(object)
        begin
          ok = object.destroy
        rescue Exception => e
          Log.info(e.response.read_body)
        end
        ok ? object : false
      end

      def build(klass, options)
        begin
          object = klass.constantize.build(options)
        rescue Exception => e
          Log.debug(e.response.read_body)
        end
        object ? object : false
      end
    end
  end
end
