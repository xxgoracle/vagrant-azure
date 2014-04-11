# Copyright (c) 2014 Mitchell Hashimoto
# Under The MIT License (MIT)
#---------------------------------------------------------------------------
# Copyright (c) Microsoft Open Technologies, Inc.
# All Rights Reserved. Licensed under the Apache 2.0 License.
#--------------------------------------------------------------------------
require "log4r"
require "vagrant/util/subprocess"
require "vagrant/util/scoped_hash_override"
require "vagrant/util/which"

module VagrantPlugins
  module WinAzure
    module Action
      # This middleware uses `rsync` to sync the folders
      class SyncFolders
        include Vagrant::Util::ScopedHashOverride

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant_azure::action::sync_folders")
        end

        def call(env)
          puts 'entered sync folders, call app'
          @app.call(env)
          puts 'called app'

          ssh_info = env[:machine].ssh_info

          unless Vagrant::Util::Which.which('rsync')
            env[:ui].warn(I18n.t('vagrant_azure.rsync_not_found_warning', :side => "host"))
            return
          end

          puts 'running which on target'
          if env[:machine].communicate.execute('which rsync', :error_check => false) != 0
            env[:ui].warn(I18n.t('vagrant_azure.rsync_not_found_warning', :side => "guest"))
            return
          end
          puts 'done running which on target'

          env[:machine].config.vm.synced_folders.each do |id, data|
            data = scoped_hash_override(data, :azure)

            # Ignore disabled shared folders
            next if data[:disabled]

            hostpath  = File.expand_path(data[:hostpath], env[:root_path])
            guestpath = data[:guestpath]

            # Make sure there is a trailing slash on the host path to
            # avoid creating an additional directory with rsync
            hostpath = "#{hostpath}/" if hostpath !~ /\/$/

            # on windows rsync.exe requires cygdrive-style paths
            if Vagrant::Util::Platform.windows?
              hostpath = hostpath.gsub(/^(\w):/) { "/cygdrive/#{$1}" }
            end

            env[:ui].info(I18n.t("vagrant_azure.rsync_folder",
                                :hostpath => hostpath,
                                :guestpath => guestpath))

            # Create the host path if it doesn't exist and option flag is set
            if data[:create]
              begin
                FileUtils::mkdir_p(hostpath)
              rescue => err
                raise Errors::MkdirError,
                  :hostpath => hostpath,
                  :err => err
              end
            end

            # Create the guest path
            env[:machine].communicate.sudo("mkdir -p '#{guestpath}'")
            env[:machine].communicate.sudo(
              "chown -R #{ssh_info[:username]} '#{guestpath}'")

            #collect rsync excludes specified :rsync_excludes=>['path1',...] in synced_folder options
            excludes = ['.vagrant/', 'Vagrantfile', *Array(data[:rsync_excludes])].uniq

            # Rsync over to the guest path using the SSH info
            command = [
              "rsync", "--verbose", "--archive", "-z",
              *excludes.map{|e|['--exclude', e]}.flatten,
              "-e", "ssh -p #{ssh_info[:port]} -o StrictHostKeyChecking=no #{ssh_key_options(ssh_info)}",
              hostpath,
              "#{ssh_info[:username]}@#{ssh_info[:host]}:#{guestpath}"]

            # we need to fix permissions when using rsync.exe on windows, see
            # http://stackoverflow.com/questions/5798807/rsync-permission-denied-created-directories-have-no-permissions
            if Vagrant::Util::Platform.windows?
              command.insert(1, "--chmod", "ugo=rwX")
            end

            puts 'executing rsync'
            r = Vagrant::Util::Subprocess.execute(*command)
            if r.exit_code != 0
              raise Errors::RsyncError,
                :guestpath => guestpath,
                :hostpath => hostpath,
                :stderr => r.stderr
            end
          end
        end

        private

        def ssh_key_options(ssh_info)
          # Ensure that `private_key_path` is an Array (for Vagrant < 1.4)
          Array(ssh_info[:private_key_path]).map { |path| "-i '#{path}' " }.join
        end
      end
    end
  end
end
