require 'spec_helper'

describe Capistrano::S3::Publisher do
  before do
    @root = File.expand_path('../', __FILE__)
    publish_file = Capistrano::S3::Publisher::LAST_PUBLISHED_FILE
    FileUtils.rm(publish_file) if File.exist?(publish_file)
  end

  describe "::files" do
    subject(:files) { described_class.files(deployment_path, exclusions) }

    let(:deployment_path) { "spec/sample-2" }
    let(:exclusions) { [] }

    it "includes dot-prefixed/hidden directories" do
      expect(files).to include("spec/sample-2/.well-known/test.txt")
    end

    it "includes dot-prefixed/hidden files" do
      expect(files).to include("spec/sample-2/public/.htaccess")
    end
  end

  context "on publish!" do
    it "publish all files" do
      Aws::S3::Client.any_instance.expects(:put_object).times(8)
      Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], [], false, {}, 'staging')
    end

    it "publish only gzip files when option is enabled" do
      Aws::S3::Client.any_instance.expects(:put_object).times(4)
      Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], [], true, {}, 'staging')
    end

    context "invalidations" do
      it "publish all files with invalidations" do
        Aws::S3::Client.any_instance.expects(:put_object).times(8)
        Aws::CloudFront::Client.any_instance.expects(:create_invalidation).once

        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', ['*'], [], false, {}, 'staging')
      end

      it "publish all files without invalidations" do
        Aws::S3::Client.any_instance.expects(:put_object).times(8)
        Aws::CloudFront::Client.any_instance.expects(:create_invalidation).never

        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], [], false, {}, 'staging')
      end
    end

    context "exclusions" do
      it "exclude one files" do
        Aws::S3::Client.any_instance.expects(:put_object).times(7)

        exclude_paths = ['fonts/cantarell-regular-webfont.svg']
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], exclude_paths, false, {}, 'staging')
      end

      it "exclude multiple files" do
        Aws::S3::Client.any_instance.expects(:put_object).times(6)

        exclude_paths = ['fonts/cantarell-regular-webfont.svg', 'fonts/cantarell-regular-webfont.svg.gz']
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], exclude_paths, false, {}, 'staging')
      end

      it "exclude directory" do
        Aws::S3::Client.any_instance.expects(:put_object).times(0)

        exclude_paths = ['fonts/**/*']
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample', '', 'cf123', [], exclude_paths, false, {}, 'staging')
      end
    end

    context "write options" do
      it "sets bucket write options to all files" do
        headers = { cache_control: 'no-cache' }
        extra_options = { write: headers }

        Aws::S3::Client.any_instance.expects(:put_object).with() { |options| contains(options, headers) }.times(3)
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample-write', '', 'cf123', [], [], false, extra_options, 'staging')
      end

      it "sets object write options to a single file" do
        headers = { cache_control: 'no-cache', acl: :private }
        extra_options = {
          object_write: {
            'index.html' => headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'index.html' && contains(options, headers) }.once
        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] != 'index.html' && !contains(options, headers) }.twice
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample-write', '', 'cf123', [], [], false, extra_options, 'staging')
      end

      it "sets object write options to a directory" do
        asset_headers = { cache_control: 'max-age=3600' }
        index_headers = { cache_control: 'no-cache' }
        extra_options = {
          object_write: {
            'assets/**' => asset_headers,
            'index.html' => index_headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'index.html' && !contains(options, asset_headers) && contains(options, index_headers) }.once
        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] != 'index.html' && !contains(options, index_headers) && contains(options, asset_headers) }.twice
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample-write', '', 'cf123', [], [], false, extra_options, 'staging')
      end

      it "sets object write permissions in the order of definition" do
        asset_headers = { cache_control: 'max-age=3600' }
        js_headers = { cache_control: 'no-cache' }
        extra_options = { object_write: { 'assets/**' => asset_headers, 'assets/script.js' => js_headers } }

        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'assets/script.js' && !contains(options, asset_headers) && contains(options, js_headers) }.once
        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'assets/style.css' && !contains(options, js_headers) && contains(options, asset_headers) }.once
        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'index.html' && !contains(options, js_headers) && !contains(options, asset_headers) }.once
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample-write', '', 'cf123', [], [], false, extra_options, 'staging')
      end

      it "overwrites object write permissions with wrong ordering" do
        js_headers = { cache_control: 'no-cache' }
        asset_headers = { cache_control: 'max-age=3600' }
        extra_options = {
          object_write: {
            'assets/script.js' => js_headers,
            'assets/**' => asset_headers
          }
        }

        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] != 'index.html' && !contains(options, js_headers) && contains(options, asset_headers) }.twice
        Aws::S3::Client.any_instance.expects(:put_object).with { |options| options[:key] == 'index.html' && !contains(options, js_headers) && !contains(options, asset_headers) }.once
        Capistrano::S3::Publisher.publish!('s3.amazonaws.com', 'abc', '123', 'mybucket.amazonaws.com', 'spec/sample-write', '', 'cf123', [], [], false, extra_options, 'staging')
      end
    end
  end
end
