require_relative "docker"
require "json"
require "digest"

module Nutkins::DockerBuilder
  def self.build cfg
    base = cfg["base"]
    raise "to use build commands you must specify the base image" unless base

    # TODO: build cache from this and use to determine restore point
    # Nutkins::Docker.run 'inspect', tag, stderr: false

    unless Nutkins::Docker.run 'inspect', base, stderr: false
      puts "getting base image"
      Docker.run 'pull', base, stdout: true
    end

    # the base image to start rebuilding from
    parent_img_id = base
    pwd = Dir.pwd
    begin
      Dir.chdir cfg["directory"]

      cache_is_dirty = false
      build_commands = cfg["build"]["commands"]
      build_commands.each do |build_cmd|
        cmd = /^\w+/.match(build_cmd).to_s.downcase
        cmd_args = build_cmd[(cmd.length + 1)..-1].strip
        # docker run is always used and forms the basis of the cache key
        run_args = nil
        env_args = nil
        add_files = nil
        add_files_dest = nil

        case cmd
        when "run"
          cmd_args.gsub! /\n+/, ' '
          run_args = cmd_args
        when "add"
          *add_files, add_files_dest = cmd_args.split ' '
          add_files = add_files.map { |src| Dir.glob src }.flatten
          # ensure checksum of each file is embedded into run command
          # if any file changes the cache is dirtied
          run_args = '#(nop) add ' + add_files.map do |src|
            src + ':' + Digest::MD5.file(src).to_s
          end.push(add_files_dest).join(' ')
        when "cmd", "entrypoint", "env", "expose", "label", "onbuild", "user", "volume", "workdir"
          run_args = "#(nop) #{build_cmd}"
          env_args = build_cmd
        else
          raise "unsupported command: #{cmd}"
          # TODO add metadata flags
        end

        if run_args
          run_shell_cmd = [ cfg['shell'], '-c', run_args ]
          unless cache_is_dirty
            # searches the commit messages of all images for the one matching the expected
            # cache entry for the given content
            cache_img_id = find_cached_img_id run_shell_cmd

            if cache_img_id
              puts "cached: #{run_args}"
              parent_img_id = cache_img_id
              next
            else
              puts "not in cache, starting from #{parent_img_id}"
              cache_is_dirty = true
            end
          end

          if run_args
            puts "run #{run_args}"
            unless Nutkins::Docker.run 'run', parent_img_id, *run_shell_cmd, stdout: true
              raise "run failed: #{run_args}"
            end

            cont_id = `docker ps -aq`.lines.first.strip
            begin
              if add_files
                add_files.each do |src|
                  if not Nutkins::Docker.run 'cp', src, "#{cont_id}:#{add_files_dest}"
                    raise "could not copy #{src} to #{cont_id}:#{add_files_dest}"
                  end
                end
              end

              commit_args = env_args ? ['-c', env_args] : []
              parent_img_id = Nutkins::Docker.run_get_stdout 'commit', *commit_args, cont_id
              raise "could not commit docker image" if parent_img_id.nil?
              parent_img_id = Nutkins::Docker.get_short_commit parent_img_id
            ensure
              if not Nutkins::Docker.run 'rm', cont_id
                puts "could not remove build container #{cont_id}"
              end
            end
          end
        else
          puts "TODO: support cmd #{build_cmd}"
        end
      end
    ensure
      Dir.chdir pwd
    end

    Nutkins::Docker.run 'tag', parent_img_id, cfg['tag']
  end

  def self.find_cached_img_id command
    all_images = Nutkins::Docker.run_get_stdout('images', '-aq').split("\n")
    images_meta = JSON.parse(Nutkins::Docker.run_get_stdout('inspect', *all_images))
    images_meta.each do |image_meta|
      if image_meta.dig('ContainerConfig', 'Cmd') == command
        return Nutkins::Docker.get_short_commit(image_meta['Id'])
      end
    end
    nil
  end
end
