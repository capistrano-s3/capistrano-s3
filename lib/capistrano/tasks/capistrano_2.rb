# frozen_string_literal: true

module Capistrano
  # rubocop:disable Metrics/BlockLength
  Configuration.instance(true).load do
    def _cset(name, *args, &block)
      set(name, *args, &block) unless exists?(name)
    end

    Capistrano::S3::Defaults.populate(self, :_cset)

    # Deployment recipes
    namespace :deploy do
      namespace :s3 do
        desc "Empties bucket of all files. Caution when using this command, as it cannot be undone!"
        task :empty do
          S3::Publisher.clear!(region, access_key_id, secret_access_key, bucket)
        end

        desc "Waits until the last CloudFront invalidation batch is completed"
        task :wait_for_invalidation do
          S3::Publisher.check_invalidation(region, access_key_id, secret_access_key,
                                           distribution_id)
        end

        desc "Upload files to the bucket in the current state"
        task :upload_files do
          extra_options = {
            write: bucket_write_options,
            redirect: redirect_options,
            object_write: object_write_options,
            prefer_cf_mime_types: prefer_cf_mime_types
          }
          S3::Publisher.publish!(region, access_key_id, secret_access_key, assume_role,
                                 bucket, deployment_path, target_path, distribution_id,
                                 invalidations, exclusions, only_gzip, extra_options)
        end
      end

      task :update do
        s3.upload_files
      end

      task :restart do
        # @todo remove?
      end
    end
  end
  # rubocop:enable Metrics/BlockLength
end
