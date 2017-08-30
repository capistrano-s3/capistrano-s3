require 'aws-sdk'
require 'mime/types'
require 'fileutils'

module Capistrano
  module S3
    module Publisher
      LAST_PUBLISHED_FILE = '.last_published'
      LAST_INVALIDATION_FILE = '.last_invalidation'

      def self.publish!(region, key, secret, bucket, deployment_path, target_path, distribution_id, invalidations, exclusions, only_gzip, extra_options, stage = 'default')
        deployment_path_absolute = File.expand_path(deployment_path, Dir.pwd)
        s3 = self.establish_s3_client_connection!(region, key, secret)
        updated = false

        self.files(deployment_path_absolute, exclusions).each do |file|
          if !File.directory?(file)
            next if self.published?(file, bucket, stage)
            next if only_gzip && self.has_gzipped_version?(file)

            path = self.base_file_path(deployment_path_absolute, file)
            path.gsub!(/^\//, "") # Remove preceding slash for S3

            self.put_object(s3, bucket, target_path, path, file, only_gzip, extra_options)
            updated = true
          end
        end

        # invalidate CloudFront distribution if needed
        if distribution_id && !invalidations.empty? && updated
          cf = self.establish_cf_client_connection!(region, key, secret)

          response = cf.create_invalidation({
            :distribution_id => distribution_id,
            :invalidation_batch => {
              :paths => {
                :quantity => invalidations.count,
                :items => invalidations.map do |path|
                  File.join('/', self.add_prefix(path, prefix: target_path))
                end
              },
              :caller_reference => SecureRandom.hex
            }
          })

          if response && response.successful?
            File.open(LAST_INVALIDATION_FILE, 'w') { |file| file.write(response[:invalidation][:id]) }
          end
        end

        self.published_to!(bucket, stage)
      end

      def self.clear!(region, key, secret, bucket, stage = 'default')
        s3 = self.establish_s3_connection!(region, key, secret)
        s3.buckets[bucket].clear!

        self.clear_published!(bucket, stage)
        FileUtils.rm(LAST_INVALIDATION_FILE)
      end

      def self.check_invalidation(region, key, secret, distribution_id, stage = 'default')
        last_invalidation_id = File.read(LAST_INVALIDATION_FILE).strip

        cf = self.establish_cf_client_connection!(region, key, secret)
        cf.wait_until(:invalidation_completed, distribution_id: distribution_id, id: last_invalidation_id) do |w|
          w.max_attempts = nil
          w.delay = 30
        end
      end

      private

        # Establishes the connection to Amazon S3
        def self.establish_connection!(klass, region, key, secret)
          # Send logging to STDOUT
          Aws.config[:logger] = ::Logger.new(STDOUT)
          Aws.config[:log_formatter] = Aws::Log::Formatter.colored
          klass.new(
            :region => region,
            :access_key_id => key,
            :secret_access_key => secret
          )
        end

        def self.establish_cf_client_connection!(region, key, secret)
          self.establish_connection!(Aws::CloudFront::Client, region, key, secret)
        end

        def self.establish_s3_client_connection!(region, key, secret)
          self.establish_connection!(Aws::S3::Client, region, key, secret)
        end

        def self.establish_s3_connection!(region, key, secret)
          self.establish_connection!(Aws::S3, region, key, secret)
        end

        def self.base_file_path(root, file)
          file.gsub(root, "")
        end

        def self.files(deployment_path, exclusions)
          Dir.glob("#{deployment_path}/**/*") - Dir.glob(exclusions.map { |e| "#{deployment_path}/#{e}" })
        end

        def self.last_published
          if File.exists? LAST_PUBLISHED_FILE
            YAML.load_file(LAST_PUBLISHED_FILE) || {}
          else
            {}
          end
        end

        def self.published_to!(bucket, stage)
          current_publish = self.last_published
          current_publish["#{bucket}::#{stage}"] = Time.now.iso8601
          File.write(LAST_PUBLISHED_FILE, current_publish.to_yaml)
        end

        def self.clear_published!(bucket, stage)
          current_publish = self.last_published
          current_publish["#{bucket}::#{stage}"] = nil
          File.write(LAST_PUBLISHED_FILE, current_publish.to_yaml)
        end

        def self.published?(file, bucket, stage)
          return false unless last_publish_time = self.last_published["#{bucket}::#{stage}"]
          File.mtime(file) < Time.parse(last_publish_time)
        end

        def self.put_object(s3, bucket, target_path, path, file, only_gzip, extra_options)
          base_name = File.basename(file)
          mime_type = mime_type_for_file(base_name)
          options   = {
            :bucket => bucket,
            :key    => self.add_prefix(path, prefix: target_path),
            :body   => open(file),
            :acl    => 'public-read',
          }

          options.merge!(build_redirect_hash(path, extra_options[:redirect]))
          options.merge!(extra_options[:write] || {})

          if mime_type
            options.merge!(build_content_type_hash(mime_type))

            if mime_type.sub_type == "gzip"
              options.merge!(build_gzip_content_encoding_hash)
              options.merge!(build_gzip_content_type_hash(file, mime_type))

              # upload as original file name
              options.merge!(key: self.add_prefix(self.orig_name(path), prefix: target_path)) if only_gzip
            end
          end

          s3.put_object(options)
        end

        def self.build_redirect_hash(path, redirect_options)
          return {} unless redirect_options && redirect_options[path]

          { :website_redirect_location => redirect_options[path] }
        end

        def self.build_content_type_hash(mime_type)
          { :content_type => mime_type.content_type }
        end

        def self.build_gzip_content_encoding_hash
          { :content_encoding => "gzip" }
        end

        def self.has_gzipped_version?(file)
          File.exist?(self.gzip_name(file))
        end

        def self.build_gzip_content_type_hash(file, mime_type)
          orig_name = self.orig_name(file)
          orig_mime = mime_type_for_file(orig_name)

          return {} unless orig_mime && File.exist?(orig_name)

          { :content_type => orig_mime.content_type }
        end

        def self.mime_type_for_file(file)
          type = MIME::Types.type_for(file)
          (type && !type.empty?) ? type[0] : nil
        end

        def self.gzip_name(file)
          "#{file}.gz"
        end

        def self.orig_name(file)
          file.sub(/\.gz$/, "")
        end

        def self.add_prefix(path, prefix:)
          if prefix.empty?
            path
          else
            File.join(prefix, path)
          end
        end
    end
  end
end
