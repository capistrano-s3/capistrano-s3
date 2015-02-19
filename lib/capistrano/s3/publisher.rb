require 'aws/s3'
require 'mime/types'
require 'fileutils'

module Capistrano::S3::Publisher

  LAST_PUBLISHED_FILE = '.last_published'

  def self.publish!(s3_endpoint, key, secret, bucket, source, extra_options)
    s3 = self.establish_s3_client_connection!(s3_endpoint, key, secret)

    self.files(source).each do |file|
      if !File.directory?(file)
        next if self.published?(file)

        path = self.base_file_path(source, file)
        path.gsub!(/^\//, "") # Remove preceding slash for S3

        self.put_object(s3, bucket, path, file, extra_options)
      end
    end

    FileUtils.touch(LAST_PUBLISHED_FILE)
  end

  def self.clear!(s3_endpoint, key, secret, bucket)
    s3 = self.establish_s3_connection!(s3_endpoint, key, secret)
    s3.buckets[bucket].clear!

    FileUtils.rm(LAST_PUBLISHED_FILE)
  end

  private

    # Establishes the connection to Amazon S3
    def self.establish_connection!(klass, s3_endpoint, key, secret)
      # Send logging to STDOUT
      AWS.config(:logger => Logger.new(STDOUT))
      klass.new(
        :s3_endpoint => s3_endpoint,
        :access_key_id => key,
        :secret_access_key => secret
      )
    end

    def self.establish_s3_client_connection!(s3_endpoint, key, secret)
      self.establish_connection!(AWS::S3::Client, s3_endpoint, key, secret)
    end

    def self.establish_s3_connection!(s3_endpoint, key, secret)
      self.establish_connection!(AWS::S3, s3_endpoint, key, secret)
    end

    def self.base_file_path(root, file)
      file.gsub(root, "")
    end

    def self.files(deployment_path)
      Dir.glob("#{deployment_path}/**/*")
    end

    def self.published?(file)
      return false unless File.exists? LAST_PUBLISHED_FILE
      File.mtime(file) < File.mtime(LAST_PUBLISHED_FILE)
    end

    def self.put_object(s3, bucket, path, file, extra_options)
      options = {
        :bucket_name => bucket,
        :key => path,
        :data => open(file),
        :acl => :public_read,
      }

      options.merge!(self.build_content_type_hash(file))
      options.merge!(self.build_redirect_hash(path, extra_options[:redirect]))
      options.merge!(self.set_content_encoding_for_gzip(file))
      options.merge!(extra_options[:write]) if extra_options[:write]

      s3.put_object(options)
    end

    def self.build_content_type_hash(file)
      type = MIME::Types.type_for(File.basename(file))
      return {} unless type && !type.empty?

      { :content_type => type.first.content_type }
    end

    def self.build_redirect_hash(path, redirect_options)
      return {} unless redirect_options && redirect_options[path]

      { :website_redirect_location => redirect_options[path] }
    end

    def self.set_content_encoding_for_gzip(file)
      type = MIME::Types.type_for(File.basename(file))
      if type && !type.empty?
        if type.first.sub_type == "gzip"
          return { :content_encoding => "gzip" } if File.exist? file.gsub /\.gz$/, ""
        end
      end
      {}
    end
end
