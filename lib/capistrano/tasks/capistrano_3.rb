namespace :load do
  task :defaults do
    Capistrano::S3::Defaults.populate(self, :set)
  end
end

namespace :deploy do
  namespace :s3 do
    desc "Empties bucket of all files. Caution when using this command, as it cannot be undone!"
    task :empty do
      Capistrano::S3::Publisher.clear!(fetch(:stage), fetch(:region), fetch(:access_key_id), fetch(:secret_access_key), fetch(:bucket))
    end

    desc "Waits until the last CloudFront invalidation batch is completed"
    task :wait_for_invalidation do
      Capistrano::S3::Publisher.check_invalidation(fetch(:region), fetch(:access_key_id), fetch(:secret_access_key), fetch(:distribution_id))
    end

    desc "Upload files to the bucket in the current state"
    task :upload_files do
      extra_options = { :write => fetch(:bucket_write_options), :redirect => fetch(:redirect_options) }
      Capistrano::S3::Publisher.publish!(fetch(:stage), fetch(:region), fetch(:access_key_id), fetch(:secret_access_key), fetch(:bucket), fetch(:deployment_path), fetch(:target_path), fetch(:distribution_id), fetch(:invalidations), fetch(:exclusions), fetch(:only_gzip), extra_options)
    end
  end

  before :updated, :upload_s3 do
    invoke("deploy:s3:upload_files")
  end
end
