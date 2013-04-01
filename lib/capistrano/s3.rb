require 'capistrano'
require 'capistrano/s3/publisher'

unless Capistrano::Configuration.respond_to?(:instance)
  abort "capistrano-s3 requires Capistrano >= 2."
end

Capistrano::Configuration.instance(true).load do
  def _cset(name, *args, &block)
    set(name, *args, &block) if !exists?(name)
  end
  
  _cset :deployment_path, Dir.pwd.gsub("\n", "") + "/public"
  _cset :bucket_write_options, :acl => :public_read
  _cset :s3_endpoint, 's3.amazonaws.com'
  
  # Deployment recipes
  namespace :deploy do
    namespace :s3 do      
      desc "Empties bucket of all files. Caution when using this command, as it cannot be undone!"
      task :empty do
        Publisher.clear!(s3_endpoint, access_key_id, secret_access_key)
      end

      desc "Upload files to the bucket in the current state"
      task :upload_files do
        Publisher.publish!(s3_endpoint, access_key_id, secret_access_key,
                           bucket, deployment_path, bucket_write_options)
      end
    end
    
    task :update do
      s3.upload_files
    end

    task :restart do; end
  end
end
