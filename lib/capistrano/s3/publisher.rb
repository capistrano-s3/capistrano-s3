# frozen_string_literal: true

require "aws-sdk"
require "mime/types"
require "fileutils"
require "capistrano/s3/mime_types"
require "yaml"

module Capistrano
  module S3
    module Publisher
      LAST_PUBLISHED_FILE = ".last_published"
      LAST_INVALIDATION_FILE = ".last_invalidation"

      class << self
        def publish!(region, key, secret, assume_role, bucket, deployment_path, target_path, distribution_id,
                     invalidations, exclusions, only_gzip, extra_options, stage = "default")
          deployment_path_absolute = File.expand_path(deployment_path, Dir.pwd)
          s3_client = establish_s3_client_connection!(region, key, secret, assume_role)

          files(deployment_path_absolute, exclusions).each do |file|
            next if File.directory?(file)
            next if published?(file, bucket, stage)
            next if only_gzip && gzipped_version?(file)

            path = base_file_path(deployment_path_absolute, file)
            path.gsub!(%r{^/}, "") # Remove preceding slash for S3

            put_object(s3_client, bucket, target_path, path, file, only_gzip, extra_options)
          end

          # invalidate CloudFront distribution if needed
          if distribution_id && !invalidations.empty?
            cf = establish_cf_client_connection!(region, key, secret, assume_role)

            response = cf.create_invalidation(
              distribution_id: distribution_id,
              invalidation_batch: {
                paths: {
                  quantity: invalidations.count,
                  items: invalidations.map do |path|
                    File.join("/", add_prefix(path, prefix: target_path))
                  end
                },
                caller_reference: SecureRandom.hex
              }
            )

            if response&.successful?
              File.write(LAST_INVALIDATION_FILE, response[:invalidation][:id])
            end
          end

          published_to!(bucket, stage)
        end

        def clear!(region, key, secret, bucket, stage = "default")
          s3 = establish_s3_connection!(region, key, secret, assume_role)
          s3.buckets[bucket].clear!

          clear_published!(bucket, stage)
          FileUtils.rm(LAST_INVALIDATION_FILE)
        end

        def check_invalidation(region, key, secret, distribution_id, _stage = "default")
          last_invalidation_id = File.read(LAST_INVALIDATION_FILE).strip

          cf = establish_cf_client_connection!(region, key, secret, assume_role)
          cf.wait_until(:invalidation_completed, distribution_id: distribution_id,
                                                 id: last_invalidation_id) do |w|
            w.max_attempts = nil
            w.delay = 30
          end
        end

        private

        # Establishes the connection to Amazon S3
        def establish_connection!(klass, region, key, secret, assume_role)

          # shared args
          args = {
            region: region,
            access_key_id: key,
            secret_access_key: secret
          }

          # Assume STS role if provided
          if assume_role

            # get the username for naming the session
            iam = Aws::IAM::Client.new(args)
            username = iam.get_user.user.user_name

            # assume role
            sts_client = Aws::STS::Client.new(args)
            role_credentials = Aws::AssumeRoleCredentials.new(
              client: sts_client,
              role_arn: assume_role,
              role_session_name: username
            )

            # update args with assumed role credentials for +klass.new+
            args[:credentials] = role_credentials if role_credentials
          end

          # Send logging to STDOUT
          Aws.config[:logger] = ::Logger.new(STDOUT)
          Aws.config[:log_formatter] = Aws::Log::Formatter.colored
          klass.new(args)
        end

        def establish_cf_client_connection!(region, key, secret, assume_role)
          establish_connection!(Aws::CloudFront::Client, region, key, secret, assume_role)
        end

        def establish_s3_client_connection!(region, key, secret, assume_role)
          establish_connection!(Aws::S3::Client, region, key, secret, assume_role)
        end

        def establish_s3_connection!(region, key, secret, assume_role)
          establish_connection!(Aws::S3, region, key, secret, assume_role)
        end

        def base_file_path(root, file)
          file.gsub(root, "")
        end

        def files(deployment_path, exclusions)
          globbed_paths = Dir.glob(
            File.join(deployment_path, "**", "*"),
            File::FNM_DOTMATCH # Else Unix-like hidden files will be ignored
          )

          excluded_paths = Dir.glob(
            exclusions.map { |e| File.join(deployment_path, e) }
          )

          globbed_paths - excluded_paths
        end

        def last_published
          if File.exist? LAST_PUBLISHED_FILE
            YAML.load_file(LAST_PUBLISHED_FILE) || {}
          else
            {}
          end
        end

        def published_to!(bucket, stage)
          current_publish = last_published
          current_publish["#{bucket}::#{stage}"] = Time.now.iso8601
          File.write(LAST_PUBLISHED_FILE, current_publish.to_yaml)
        end

        def clear_published!(bucket, stage)
          current_publish = last_published
          current_publish["#{bucket}::#{stage}"] = nil
          File.write(LAST_PUBLISHED_FILE, current_publish.to_yaml)
        end

        def published?(file, bucket, stage)
          return false unless (last_publish_time = last_published["#{bucket}::#{stage}"])

          File.mtime(file) < Time.parse(last_publish_time)
        end

        def put_object(s3_client, bucket, target_path, path, file, only_gzip, extra_options)
          prefer_cf_mime_types = extra_options[:prefer_cf_mime_types] || false

          base_name = File.basename(file)
          mime_type = mime_type_for_file(base_name, prefer_cf_mime_types)
          options   = {
            bucket: bucket,
            key: add_prefix(path, prefix: target_path),
            body: File.read(file),
            acl: "public-read"
          }

          options.merge!(build_redirect_hash(path, extra_options[:redirect]))
          options.merge!(extra_options[:write] || {})

          object_write_options = extra_options[:object_write] || {}
          object_write_options.each do |pattern, object_options|
            options.merge!(object_options) if File.fnmatch(pattern, options[:key])
          end

          if mime_type
            options.merge!(build_content_type_hash(mime_type))

            if mime_type.sub_type == "gzip"
              options.merge!(build_gzip_content_encoding_hash)
              options.merge!(build_gzip_content_type_hash(file, mime_type, prefer_cf_mime_types))

              # upload as original file name
              options[:key] = add_prefix(orig_name(path), prefix: target_path) if only_gzip
            end
          end

          s3_client.put_object(options)
        end

        def build_redirect_hash(path, redirect_options)
          return {} unless redirect_options && redirect_options[path]

          { website_redirect_location: redirect_options[path] }
        end

        def build_content_type_hash(mime_type)
          { content_type: mime_type.content_type }
        end

        def build_gzip_content_encoding_hash
          { content_encoding: "gzip" }
        end

        def gzipped_version?(file)
          File.exist?(gzip_name(file))
        end

        def build_gzip_content_type_hash(file, _mime_type, prefer_cf_mime_types)
          orig_name = orig_name(file)
          orig_mime = mime_type_for_file(orig_name, prefer_cf_mime_types)

          return {} unless orig_mime && File.exist?(orig_name)

          { content_type: orig_mime.content_type }
        end

        def mime_type_for_file(file, prefer_cf_mime_types)
          types = MIME::Types.type_for(file)

          if prefer_cf_mime_types
            intersection = types & Capistrano::S3::MIMETypes::CF_MIME_TYPES

            types = intersection unless intersection.empty?
          end

          types.first
        end

        def gzip_name(file)
          "#{file}.gz"
        end

        def orig_name(file)
          file.sub(/\.gz$/, "")
        end

        def add_prefix(path, prefix:)
          if prefix.empty?
            path
          else
            File.join(prefix, path)
          end
        end
      end
    end
  end
end
